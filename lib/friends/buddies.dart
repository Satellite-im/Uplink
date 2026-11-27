import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../desk_stamp.dart';
import '../games/game_activity.dart';
import '../invites/pending_invites.dart';
import '../me/me.dart';
import '../me/cosmetics.dart';
import '../me/lookup_budget.dart';
import '../me/own_links.dart';
import '../me/pictures.dart';
import '../net/carrier.dart';
import '../net/crypto.dart';
import '../net/home_record.dart';
import '../net/homes.dart';
import '../net/name_watch.dart';
import '../net/net.dart';
import '../net/packet.dart';
import '../net/switchboard.dart';
import '../sms.dart';
import '../sounds.dart';
import 'vouches.dart';

/// Someone added by their username on Uplink, with no phone number between the two (Matt, 2026-11-14:
/// "create a profile and username under "me" to register a username and add friends on the platform").
@immutable
class Buddy {
  const Buddy({required this.username, required this.id, required this.key, this.name = '', this.bio = '', this.state = 'yes', this.at = 0, this.picture = '', this.status = '', this.links = const {}, this.cosmetics = Cosmetics.none, this.home, this.check = '', this.banner = '', this.own = const []});

  /// Their username, as the relay server's directory has it: `maya`, or `maya@relay.example` for someone who was
  /// added on another relay (lib/net/home_record.dart, splitUsername).
  final String username;

  /// Their home record, as they signed it (lib/net/home_record.dart): where they live, which this app's relay is
  /// given so it can pass packets on to theirs. Checked before it is kept; null where they have said none (a build
  /// from before relays talked to each other).
  final Map<String, Object?>? home;

  /// The count of their home record; 0 with none.
  int get homeCount => home?['n'] is int ? home!['n'] as int : 0;

  /// The relay their record names, as a person reads it (`relay.example`); '' with no record.
  String get homeHost {
    final h = home?['h'];
    if (h is! List) return '';
    return h.whereType<String>().map(hostOfHome).firstWhere((x) => x.isNotEmpty, orElse: () => '');
  }

  /// Their install's name (NetCrypto.idOf their key) and their public key in base64: what packets to them are sealed
  /// with, as the phone works it out (android Buddies.kt).
  final String id;
  final String key;

  /// What they said about themselves: sent by them, kept here, never asked of the server.
  final String name;
  final String bio;

  /// Their picture (a square base64 PNG: lib/me/pictures.dart) and how they are now, as they last said; '' for none.
  final String picture;
  final String status;

  /// Their number (`phone`) and the accounts they linked (network to handle), where they chose to tell friends.
  final Map<String, String> links;

  /// Where the two stand: `asked` (this phone asked them), `invited` (they asked this phone), `yes`; or `blocked`
  /// (GMFB-40): kept only so their friend requests and messages are dropped, never given a sealing key (android
  /// Buddies.kt and Chats.peersOf take only the other three).
  final String state;

  /// When this phone asked them or was asked, ms since 1970.
  final int at;

  /// Their name, else their username, with no "@" in front (bareName).
  String get shown => name.isEmpty ? bareName(username) : bareName(name);

  /// What their profile wears, as they last said (lib/me/cosmetics.dart).
  final Cosmetics cosmetics;

  /// Their own picture as their banner (GMFB-34; ProfilePictures.goodBanner), as they last said; '' for none, where
  /// the banner [cosmetics] names is drawn.
  final String banner;

  /// The links they typed for their profile (lib/me/own_links.dart), as they last said: theirs by their word alone.
  final List<OwnLink> own;

  /// What the relay's directory last said of [username], for a request (found in review, 2026-11-23): `ok`, it gives
  /// [id] for it; `other`, it gives it to another install; `nobody`, it knows no such name (it may be another relay's);
  /// '' not asked yet, or the relay couldn't be asked. A request names its own username, and anyone can send one: an
  /// accepted request that named itself "maya" took what was written to @maya. So a new request is not kept where the
  /// directory gives its name to someone else, and one is accepted only once it says `ok`; the rest are kept, shown as not
  /// checked, and asked about again. Someone this phone asked was looked up by the asking.
  final String check;

  /// The directory gives [username] for this install ([check]).
  bool get checked => check == 'ok';

  Buddy copyWith({String? username, String? name, String? bio, String? state, String? picture, String? status, Map<String, String>? links, Cosmetics? cosmetics, Map<String, Object?>? home, String? check, String? banner, List<OwnLink>? own}) => Buddy(
      username: username ?? this.username,
      id: id,
      key: key,
      name: name ?? this.name,
      bio: bio ?? this.bio,
      state: state ?? this.state,
      at: at,
      picture: picture ?? this.picture,
      status: status ?? this.status,
      links: links ?? this.links,
      cosmetics: cosmetics ?? this.cosmetics,
      home: home ?? this.home,
      check: check ?? this.check,
      banner: banner ?? this.banner,
      own: own ?? this.own);

  Map<String, Object> toJson() => {'u': username, 'i': id, 'k': key, 'n': name, 'b': bio, 's': state, 'a': at, if (picture.isNotEmpty) 'p': picture, if (status.isNotEmpty) 'st': status, if (links.isNotEmpty) 'l': links, if (!cosmetics.isEmpty) 'cx': cosmetics.toJson(), 'h': ?home, if (check.isNotEmpty) 'ck': check, if (banner.isNotEmpty) 'bp': banner, if (own.isNotEmpty) 'ol': [for (final l in own) l.toJson()]};

  /// Links as sent or kept: network to handle, short strings only; null where none were said.
  static Map<String, String>? _linksOf(Object? l) {
    if (l is! Map) return null;
    return {for (final e in l.entries.take(12)) if (e.key is String && e.value is String && (e.value as String).length <= 80) e.key as String: e.value as String};
  }

  /// The buddy [j] is; null without a username, an id and a key. A picture over the limit is left out.
  static Buddy? fromJson(Object? j) {
    if (j is! Map) return null;
    final u = j['u'], i = j['i'], k = j['k'];
    if (u is! String || i is! String || k is! String) return null;
    final p = j['p'] is String && (j['p'] as String).length <= ProfilePictures.most ? j['p'] as String : '';
    final ck = j['ck'];
    return Buddy(username: u, id: i, key: k, name: '${j['n'] ?? ''}', bio: '${j['b'] ?? ''}', state: '${j['s'] ?? 'yes'}', at: (j['a'] as num?)?.toInt() ?? 0, picture: p, status: '${j['st'] ?? ''}', links: _linksOf(j['l']) ?? const {}, cosmetics: Cosmetics.fromJson(j['cx']) ?? Cosmetics.none, home: j['h'] is Map ? (j['h'] as Map).cast<String, Object?>() : null, check: ck == true ? 'ok' : (const {'ok', 'other', 'nobody'}.contains(ck) ? ck as String : ''), banner: _bannerOf(j['bp']) ?? '', own: OwnLink.listOf(j['ol']) ?? const []);
  }

  /// A banner picture as sent or kept: '' for none or one that can't be one; null where nothing was said.
  static String? _bannerOf(Object? bp) => bp is! String ? null : (ProfilePictures.goodBanner(bp) ? bp : '');
}

/// What [Buddies] stands on: the directory, the routes, the phone. The app's is [_AppBuddiesPort]; a test gives
/// two that reach each other.
abstract class BuddiesPort {
  /// This install's name and public key (base64).
  Future<({String id, String key})> me();

  /// This person's own username, name and line; and who has [username] in the relay's directory (null for nobody).
  String? get username;
  String get displayName;
  String get bio;
  Future<({String id, String key})?> whois(String username);

  /// Keeps the list where the phone works out each one's sealing key from, and reads the people again.
  Future<void> keep(String json);
  Future<String> kept();

  /// Sends [envelope]: sealed to someone a key is held for, or in the clear ([sealed] false, a request).
  Future<bool> send(String id, Envelope envelope, {bool sealed = true});

  /// What comes sealed from someone a key is held for, and the greetings in the clear from anyone.
  Stream<({String from, Envelope envelope})> get received;
  Stream<({String from, Envelope envelope})> get greetings;
}

/// What a [BuddiesPort] adds where the account can sign (lib/friends/vouches.dart): the app's signs with the key the
/// routes sign with, kept where the install keeps its keys. A port without it can't vouch for anyone; it still keeps
/// and counts the vouches friends send and carry.
abstract class BuddiesSigner {
  /// The account's signature over [message]: r then s, 64 bytes.
  Future<Uint8List> sign(List<int> message);
}

/// What a [BuddiesPort] adds where the account has other devices of its own (GMFB-33): a sealed envelope to them, by
/// the way a message's copy goes (lib/friends/friends.dart, Friends.copyKind). What they send comes in [BuddiesPort.received]
/// under this account's own name. A port without it tells no other device anything, as every port did before.
abstract class BuddiesMine {
  /// Sends [envelope] to this account's other devices; false where nothing took it.
  Future<bool> sendMine(Envelope envelope);
}

/// What a [BuddiesPort] adds where relays talk to each other (docs/OPEN_NETWORK.md, section 4): this account's home
/// record and the giving of friends' records to the relay ([Homes]), and whether what was sent someone crossed to their
/// relay. A port without it knows one relay only, as every port did before: nobody on another relay can be added
/// through it, and nothing else changes.
abstract class BuddiesAcross {
  /// This account's home record and what the relay is told of where friends live; null until the routes are set up.
  Homes? get homes;

  /// Tells when [homes] is another one, or this account's record in it changed.
  Listenable get homesChanged;

  /// Whether the last thing sent to [id] was passed by this app's relay to another relay (or is kept for one). False
  /// where the relay only kept it here, as it does for someone who lives on it.
  bool passedOn(String id);

  /// Why the last thing sent to [id] was refused, as the relay said it (their relay refused it, can't be reached, is
  /// holding too much); null where it wasn't.
  String? refusedWhy(String id);

  /// Something small kept with the app's choices, and read back.
  String recall(String key);
  void remember(String key, String value);
}

/// Friends by username. Becoming friends is said over the routes as envelopes of kind `buddy`:
///
/// - **ask**, in the clear, as a greeting (`hello` with `buddy: ask`), carrying the asker's username, name, line and
///   public key. Anyone can send it; the hub says who sent it, and the key is checked against that name, so it can't
///   be sent in someone else's name. It is shown as a request, and nothing more is taken from it.
/// - **yes**, sealed: the other said yes. Their name and line come with it. Two who ask each other are friends.
/// - **no** and **end**, sealed: no, or no longer.
/// - **me**, sealed: a friend changed their name or line.
///
/// The list is kept on the phone (`buddies`), and the phone works out the key each pair seals with from it, so the
/// routes reach them as they reach anyone encryption is on with.
///
/// **Friends on another relay** (docs/OPEN_NETWORK.md, section 4; Matt, 2026-11-22: "I'd like the relays to be able to
/// talk to each other"). `maya@relay.example` is asked of that relay ([Homes.whois]) and kept with her home record,
/// which this app's relay is given so it can pass packets on to hers; nothing else about sending changes. The ask
/// carries the asker's own record (`h`), so the answer can find its way back, and friends tell each other their
/// record with a sealed envelope of kind `home` (`{"rec": …}`): when two become friends, and whenever it changes (the
/// account moved to another relay), a friend at a time ([spread]). A record is kept only where it is that friend's
/// own, by their key, and newer than the one held.
/// What [Buddies.lookup] found.
/// What a username typed is: nobody's, this account's, someone's here, or a name on another relay, which is asked of
/// that relay only when the person asks to add them ([Buddies.add]), never as they type.
enum BuddyLookup { nobody, you, someone, elsewhere }

/// Friends by username on this install: the list, the requests either way, and what friends are told of this
/// person. On a computer paired with a phone it asks the phone for everything.
///
/// Becoming friends is said over the routes as envelopes of kind `buddy`:
/// - **ask**, in the clear, as a greeting (`hello` with `buddy: ask`), carrying the asker's username, name, line
///   and public key. Anyone can send it; the hub says who sent it, and the key is checked against that name, so it
///   can't be sent in someone else's name. It is shown as a request, and nothing more is taken from it.
/// - **yes**, sealed: the other said yes; their name and line come with it. Two who ask each other are friends.
/// - **no** and **end**, sealed: no, or no longer. **me**, sealed: a friend changed their name or line.
///
/// The list is kept on the phone (`buddies`), and the phone works out the key each pair seals with from it, so
/// the routes reach them as they reach anyone encryption is on with.
class Buddies extends ChangeNotifier {
  /// What the phone last said its friends are, as it said it ([refresh]).
  String? _lastSaid;

  /// [lookups]: the account's budget of lookups made of the app's own accord, which the name watch shares (the app's
  /// own: LookupBudget.instance); one of its own where none is given.
  Buddies(this._port, {this.spread = const Duration(seconds: 2), this.carryAfter = const Duration(minutes: 3), LookupBudget? lookups, Vouches? vouches})
      : _lookups = lookups ?? LookupBudget(),
        _vouches = vouches;

  /// How long between one friend being told this account's new home record and the next: not all at once.
  final Duration spread;

  static Buddies? _instance;
  static Buddies get instance => _instance ??= Buddies(_AppBuddiesPort(), lookups: LookupBudget.instance);

  @visibleForTesting
  static set instance(Buddies? b) => _instance = b;

  final BuddiesPort _port;
  final LookupBudget _lookups;
  final List<StreamSubscription<Object?>> _subs = [];

  /// Everyone a request has passed between, whatever its state.
  List<Buddy> all = [];
  bool _started = false;

  /// Those who said yes, or were said yes to.
  List<Buddy> get friends => [for (final b in all) if (b.state == 'yes') b];

  /// [friends] as a list shows them: one each, by username (Matt, 2026-11-19: "my friends are duplicated I have two
  /// copies of all my friends on the app"). The same person can be here twice, under two ids (an install of theirs
  /// that came again with a new key, or a list put together from a phone's and a computer's); the newest stands for
  /// them. [friends] keeps every id, for what is sent to each.
  List<Buddy> get shownFriends => onePerUsername(friends);

  /// [shownFriends] who can come into a room on this app's relay: a circle's, a space's, a call's. Rooms don't cross
  /// relays yet, so a friend on another relay is not offered for one (found in the review, 2026-11-23).
  List<Buddy> get roomFriends => [for (final b in shownFriends) if (!elsewhere(b)) b];

  /// [list] with one [Buddy] for each username (letters' case aside), the latest ([Buddy.at]) of each, in [list]'s order.
  static List<Buddy> onePerUsername(List<Buddy> list) {
    final best = <String, Buddy>{};
    for (final b in list) {
      final k = b.username.toLowerCase();
      final had = best[k];
      if (had == null || b.at > had.at) best[k] = b;
    }
    final seen = <String>{};
    return [
      for (final b in list)
        if (identical(best[b.username.toLowerCase()], b) && seen.add(b.username.toLowerCase())) b,
    ];
  }

  /// Those who asked this person and wait for an answer; and those this person asked.
  List<Buddy> get requests => [for (final b in all) if (b.state == 'invited') b];
  List<Buddy> get asked => [for (final b in all) if (b.state == 'asked') b];

  /// Uplink people this phone blocked (GMFB-40: "Reporting a person also offers to block them").
  List<Buddy> get blocked => [for (final b in all) if (b.state == 'blocked') b];

  bool isBlocked(String id) => byId(id)?.state == 'blocked';

  /// Blocks the Uplink person [id] ([username], [key] where known): no longer friends (they are told, as removing a
  /// friend tells them), and their friend requests and messages are dropped here from now on. Asking them to be friends
  /// again ([add]) takes the block away.
  Future<void> block(String id, {String username = '', String key = ''}) async {
    if (_remote) {
      await _ask({'op': 'block', 'id': id, 'u': username, 'k': key});
      return;
    }
    final had = byId(id);
    if (had?.state == 'yes' || had?.state == 'asked') await _port.send(id, Envelope(kind: 'buddy', body: {'s': 'end'}));
    if (had?.state == 'invited') await _port.send(id, Envelope(kind: 'buddy', body: {'s': 'no'}));
    GameActivities.instance.heard(id, null);
    final b = had == null
        ? Buddy(username: tidyHandle(username), id: id, key: key, state: 'blocked', at: DateTime.now().millisecondsSinceEpoch)
        : Buddy(username: had.username, id: id, key: had.key, name: had.name, state: 'blocked', at: DateTime.now().millisecondsSinceEpoch, picture: had.picture);
    all = [for (final o in all) if (o.id != id) o, b];
    _homes?.forget(id);
    _dropVouches(id);
    _unreached.remove(id);
    await _save();
  }

  /// Takes the block on [b] away: they are forgotten here, as if never met.
  Future<void> unblock(Buddy b) async {
    if (_remote) {
      await _ask({'op': 'unblock', 'id': b.id});
      return;
    }
    all = [for (final o in all) if (o.id != b.id) o];
    await _save();
  }

  Buddy? byId(String id) {
    for (final b in all) {
      if (b.id == id) return b;
    }
    return null;
  }

  // --- on a computer paired with a phone (Matt, 2026-11-18: "I don't see the ability to add friends on desktop") ------
  //
  // Friends by username are the phone's: its routes reach them and its keys seal to them. A paired computer asks the
  // phone for each thing done (android DeskCalls "buddies", answered by the phone's [forComputer]) and holds the list
  // the phone answers with, asked again every little while so a request made to the phone shows here.

  /// Whether this is a computer's, speaking through its phone.
  bool get _remote => !Sms.ownNetwork && _port is _AppBuddiesPort;
  Timer? _poll;

  /// Asks again, now and then, for a friend request not yet answered ([askAgain]).
  Timer? _again;

  /// How long an unanswered request is asked again for.
  static const askFor = Duration(days: 14);

  /// How often.
  static const askEvery = Duration(minutes: 5);

  /// On a computer: asks the phone to do [what], and takes the list it answers with. A refusal comes as a [MeError].
  Future<Map<String, Object?>> _ask(Map<String, Object?> what) async {
    final Map<String, dynamic> r;
    try {
      r = await Sms.instance.buddies(what);
    } on MeError {
      rethrow;
    } catch (e) {
      final m = RegExp(r'^PlatformException\([^,]*, (.*?), .*\)$', dotAll: true).firstMatch('$e');
      throw MeError(m?.group(1) ?? '$e');
    }
    final list = r['list'];
    if (list is List) {
      // Asked of the phone every twenty seconds: the listeners (the rail, people's faces) are told only when the
      // friends are different from the last asking (docs/performance-audit.md, finding 8).
      final said = jsonEncode(list);
      final same = said == _lastSaid;
      _lastSaid = said;
      all = [for (final j in list) ?Buddy.fromJson(j)];
      if (!same) notifyListeners();
    }
    // What the phone's friends are playing (lib/games/game_activity.dart): said to the phone, so told here by it.
    if (r['ga'] is Map) GameActivities.instance.heardAll(r['ga']);
    return r;
  }

  /// Takes [json] as the whole list (a paired computer's and this phone's, put together: lib/friends/handover.dart).
  Future<void> takeAll(String json) async {
    try {
      all = [for (final j in jsonDecode(json) as List) ?Buddy.fromJson(j)];
    } catch (_) {
      return;
    }
    // Where each lives, for the relay to route by: friends', and those this account asked; never a stranger's who
    // only asked.
    for (final b in all) {
      if (b.home != null && _routed(b)) _homes?.give(b.home!);
    }
    await _save();
  }

  /// Whether [b]'s record is given to the relay to route by: a friend's, or one this account asked to be friends.
  /// A stranger's request is not: their record is given only once it is answered yes (found in the review,
  /// 2026-11-23: spam requests' records were said at every sign-in, and cost the relay's checks).
  static bool _routed(Buddy b) => b.state == 'yes' || b.state == 'asked';

  /// The phone's list read again, on a computer; nothing anywhere else.
  Future<void> refresh() async {
    if (!_remote) return;
    try {
      final r = await _ask({'op': 'list', if (_phoneStamp != null) 'have': _phoneStamp});
      // The mark of the list the phone gave (lib/desk_stamp.dart), said back next time; none from a phone from before.
      _phoneStamp = r['stamp'] is String ? r['stamp'] as String : null;
    } catch (_) {}
  }

  /// On a computer: the mark the phone gave its friends list last, so that an unchanged list comes as a word.
  String? _phoneStamp;

  /// On the phone: what a paired computer asks of friends by username ([_ask] there). Each answer carries the list.
  Future<Object?> forComputer(Map<String, Object?> what) async {
    Buddy want() => byId('${what['id']}') ?? (throw MeError('That friend request is no longer here.'));
    List<Object> list() => [for (final b in all) b.toJson()];
    switch (what['op']) {
      case 'lookup':
        return {'found': (await lookup('${what['u'] ?? ''}')).name, 'list': list()};
      case 'add':
        final b = await add('${what['u'] ?? ''}', keyPrefix: what['kp'] is String ? what['kp'] as String : null);
        return {'buddy': b.toJson(), 'list': list()};
      case 'accept':
        final b = await accept(want());
        return {'buddy': b.toJson(), 'list': list()};
      case 'decline':
        await decline(want());
      case 'remove':
        await remove(want());
      case 'block':
        await block('${what['id'] ?? ''}', username: '${what['u'] ?? ''}', key: '${what['k'] ?? ''}');
      case 'unblock':
        await unblock(want());
      case 'share':
        await shareProfile();
      case 'ga':
        // The computer's game, said to friends in this phone's name: the phone is who they are friends with.
        await sayActivity(GameActivity.fromJson(what['ga']));
    }
    final answer = <String, Object?>{'list': list(), 'ga': GameActivities.instance.all()};
    // The computer's asking every twenty seconds, answered in a word where it has all of this already ([stampedFor]).
    return what['op'] == 'list' ? stampedFor(what['have'], answer) : answer;
  }

  /// On a phone: reads the kept list, listens to the routes, and begins asking unanswered requests again. On a
  /// paired computer: reads the phone's list, now and every twenty seconds.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    if (_remote) {
      await refresh();
      _poll = Timer.periodic(const Duration(seconds: 20), (_) => refresh());
      return;
    }
    // Invites texted to this phone's number before it had the app, waiting on the relay: taken once the number is
    // verified in Settings › Me (lib/invites/pending_invites.dart; Matt, 2026-11-17: "a link that eventually follows
    // through after they setup their account"). Started with the app's friends, on the phone or an iPhone of its own.
    if (identical(this, _instance) && _port is _AppBuddiesPort) PendingInvites.instance.start();
    try {
      all = [for (final j in jsonDecode(await _port.kept()) as List) ?Buddy.fromJson(j)];
    } catch (_) {
      all = [];
    }
    // This account's vouches (lib/friends/vouches.dart), kept under its own name.
    try {
      final me = _me = await _port.me();
      vouches.load(me.id, key: me.key);
      _carryIfOwed();
    } catch (_) {}
    _subs.add(_port.greetings.listen((g) => unawaited(_greeting(g.from, g.envelope))));
    _subs.add(_port.received.listen((r) => _sealed(r.from, r.envelope)));
    // A part of the profile changed here: the account's other devices are told, a little after (Me.ownChanged).
    _subs.add(Me.instance.ownChanged.listen(_ownProfileSoon));
    // Home records: friends' are given to the relay, and friends are told this account's when they need it.
    final across = _across;
    if (across != null) {
      across.homesChanged.addListener(_homesChanged);
      _homesChanged();
    }
    notifyListeners();
    // A request the hub was holding for someone away is lost when the relay restarts, and so is an answer, and nothing
    // asked again (Matt, 2026-11-19: "my friend request to morgan never went through i also sent one from her phone and
    // it didn't go out"; the relay restarted five times that evening, one deploy each). Each unanswered request is
    // asked again: a little after starting, once the hub is reached, and every few minutes, for two weeks. The other
    // side takes a request it holds already as the same one, and answers one it has said yes to again.
    Timer(const Duration(seconds: 15), () {
      unawaited(askAgain().then((_) => checkRequests()));
      // The account's other devices are asked what they vouched for, and told what this one did (GMFB-33).
      unawaited(syncVouches(ask: true));
      // And what they have of the profile that is newer than this one's (a picture changed while this was closed).
      unawaited(askOwnProfile());
    });
    _again = Timer.periodic(askEvery, (_) {
      unawaited(askAgain().then((_) => checkRequests()));
      // Asked again until the routes took it once.
      if (!_ownAsked) unawaited(syncVouches(ask: true));
      if (!_profileAsked) unawaited(askOwnProfile());
      // And whoever has not heard this account's home record yet (the relay was away when they were to be told).
      _tellSoon();
    });
  }

  // --- home records (docs/OPEN_NETWORK.md, section 4) ---------------------------------------------------------------

  BuddiesAcross? get _across => _port is BuddiesAcross ? _port as BuddiesAcross : null;
  Homes? get _homes => _across?.homes;

  /// What is kept of telling friends this account's record, for one account (a second account on this device keeps
  /// its own): the count of it each friend is known to hold (they said so: [_told]), the count last sent each
  /// ([_sentHome]), and the relay the record named when friends were last told ([_toldWhere]). The keys of the build
  /// before (`buddies_home_told`) counted a friend as told when the envelope merely went, and are not read.
  static String _toldKey(String me) => 'buddies_home_told2:$me';

  /// The count of this account's home record each friend holds, by their id, as they said themselves.
  final Map<String, int> _told = {};

  /// The count last sent each, so the same record is not sent again to a friend who never answers (an app from before
  /// passes it over).
  final Map<String, int> _sentHome = {};

  /// The addresses the record named when friends were last told, and whose told-state is loaded.
  List<String> _toldWhere = const [];
  String? _toldFor;

  /// When each friend was last sent the record in answer to theirs: no more than one such answer a minute to a friend.
  final Map<String, DateTime> _repliedAt = {};

  /// Those still to be told the record there is now, a friend at a time.
  final List<String> _toTell = [];
  Timer? _teller;

  /// The [Homes] that has been given the friends' records: another one (the routes started again) is given them anew.
  Homes? _givenTo;

  /// Those whose friend request the relay could not pass to their relay when it was last sent.
  final Set<String> _unreached = {};

  /// Whether [b] lives on another relay than this app's, by their home record.
  bool elsewhere(Buddy b) {
    final homes = _homes;
    final h = b.home?['h'];
    return homes != null && h is List && h.isNotEmpty && !homes.namesHere(h.whereType<String>());
  }

  /// Whether this app's relay passes messages to other relays, as it said itself.
  bool get relayTalks => _homes?.relayTalks ?? false;

  /// Whether [b] is on another relay as far as who is here and calls go: [elsewhere], and only where this app's relay
  /// talks to others. Where it doesn't, a friend can be reached through it only on it, so in doubt (a relay known by
  /// more than one name) they are taken to be here (found in the review, 2026-11-23).
  bool apart(Buddy b) => elsewhere(b) && (_homes?.relayTalks ?? false);

  /// The relay [b] is on where it isn't this app's (`relay.example`), for their card; '' where it is, or isn't known.
  String relayOf(Buddy b) => elsewhere(b) ? b.homeHost : '';

  /// Whether the friend request to [b], who lives on another relay, could not be passed to their relay when it was
  /// last sent: this app's relay doesn't talk to theirs. It is sent again by itself ([askAgain]), and goes when it can.
  bool unreached(Buddy b) => _unreached.contains(b.id);

  /// Why the request to [b] couldn't be passed on, as the relay said it; null where it only doesn't talk to theirs.
  String? unreachedWhy(Buddy b) => _across?.refusedWhy(b.id);

  /// A username as it can be added: `maya`, or `maya@relay.example` (with or without an `@` in front).
  static bool goodAddress(String typed) {
    final t = splitUsername(typed);
    return Me.goodUsername(t.name) && (t.relay == null || goodRelayHost(t.relay!));
  }

  /// The routes were set up, or this account's home record changed.
  void _homesChanged() {
    final homes = _homes;
    if (homes == null) return;
    _loadTold(homes.signer.id);
    homes.beforeLeaving = _tellBeforeLeaving;
    if (!identical(homes, _givenTo)) {
      _givenTo = homes;
      for (final b in all) {
        if (b.home != null && _routed(b)) homes.give(b.home!);
      }
    }
    _tellSoon();
  }

  /// Reads what is kept of telling friends, for the account [me]; once for an account.
  void _loadTold(String me) {
    if (_toldFor == me) return;
    _toldFor = me;
    _told.clear();
    _sentHome.clear();
    _toldWhere = const [];
    final across = _across;
    if (across == null) return;
    try {
      final kept = jsonDecode(across.recall(_toldKey(me)));
      if (kept is Map) {
        for (final (into, from) in [(_told, kept['told']), (_sentHome, kept['sent'])]) {
          if (from is Map) into.addAll({for (final e in from.entries) if (e.value is int) '${e.key}': e.value as int});
        }
        if (kept['where'] is List) _toldWhere = (kept['where'] as List).whereType<String>().toList();
      }
    } catch (_) {}
  }

  /// Keeps it, without those who are friends no longer.
  void _keepTold() {
    final me = _toldFor, across = _across;
    if (me == null || across == null) return;
    _told.removeWhere((k, _) => byId(k) == null);
    _sentHome.removeWhere((k, _) => byId(k) == null);
    across.remember(_toldKey(me), jsonEncode({'told': _told, 'sent': _sentHome, 'where': _toldWhere}));
  }

  /// Queues the friends who need this account's record as it is now, a friend at a time ([spread]): all of them where
  /// it names another relay than when they were last told (this account moved), else those on other relays (whose
  /// relays route by it, and whose copy runs out); never the same record twice to one friend who never answered, and
  /// none at all the first time, when every friend is on the relay this account is (found in the review, 2026-11-23: a
  /// first start sent every friend an envelope, and each closed iPhone a "New message").
  void _tellSoon() {
    final mine = _homes?.mine;
    if (mine == null || _toldFor == null) return;
    final moved = _toldWhere.isNotEmpty && !_sameAddresses(_toldWhere, mine.h);
    if (_toldWhere.isEmpty) {
      _toldWhere = mine.h;
      _keepTold();
    }
    for (final b in friends) {
      if ((_told[b.id] ?? 0) >= mine.n || _sentHome[b.id] == mine.n || _toTell.contains(b.id)) continue;
      if (moved || elsewhere(b)) _toTell.add(b.id);
    }
    if (moved) {
      _toldWhere = mine.h;
      _keepTold();
    }
    if (_toTell.isNotEmpty) _teller ??= Timer.periodic(spread, (_) => unawaited(tellNext()));
  }

  /// This account is moving, and still connected to the relay it leaves: each friend on that relay is told where it
  /// lives now, through it, while they can be reached; once they hear it they answer with theirs (if this app holds
  /// none of theirs), which follows this account to its new relay (found in the review, 2026-11-23: a friend whose
  /// record this app never held could not be reached from the new relay, and what was written there waited for nobody).
  Future<void> _tellBeforeLeaving() async {
    final mine = _homes?.mine;
    if (mine == null) return;
    await Future.wait([
      for (final b in friends)
        if (!elsewhere(b) && _sentHome[b.id] != mine.n) _tellHome(b.id),
    ]);
  }

  static bool _sameAddresses(List<String> a, List<String> b) => a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((x) => x);

  /// Tells the next friend waiting this account's home record; true where there was one to tell. The timer calls it;
  /// a test calls it itself.
  @visibleForTesting
  Future<bool> tellNext() async {
    if (_toTell.isEmpty) {
      _teller?.cancel();
      _teller = null;
      return false;
    }
    final id = _toTell.removeAt(0);
    if (_toTell.isEmpty) {
      _teller?.cancel();
      _teller = null;
    }
    // Told already as this account left the relay they are on: not twice.
    if (_sentHome[id] != _homes?.mine?.n) await _tellHome(id);
    return true;
  }

  /// How many friends are still to be told, for a test.
  @visibleForTesting
  int get waitingToHear => _toTell.length;

  /// Tells [id] this account's home record, sealed, with the count of theirs this app holds (`has`), so they can say
  /// back whether they need ours and we can tell whether they hold it. Sent is not told: a friend counts as told only
  /// when they say so ([_heardHome]); what is kept is that this record was sent them, so it is not sent again.
  Future<void> _tellHome(String id) async {
    final across = _across;
    final mine = across?.homes?.mine;
    final b = byId(id);
    if (across == null || mine == null || b?.state != 'yes') return;
    final bool sent;
    try {
      sent = await _port.send(id, Envelope(kind: 'home', body: {'rec': mine.toJson(), 'has': b!.homeCount}));
    } catch (_) {
      return;
    }
    if (!sent) return;
    _sentHome[id] = mine.n;
    _keepTold();
  }

  /// Of two records of one friend's (as JSON, already checked), the one believed (HomeRecord.order); null with none.
  static Map<String, Object?>? _newerOf(Map<String, Object?>? x, Map<String, Object?>? y) {
    final a = x == null ? null : HomeRecord.check(x, now: DateTime.fromMillisecondsSinceEpoch((x['t'] as int?) ?? 0));
    final b = y == null ? null : HomeRecord.check(y, now: DateTime.fromMillisecondsSinceEpoch((y['t'] as int?) ?? 0));
    if (a == null) return b == null ? null : y;
    if (b == null) return x;
    return a.newerThan(b) ? x : y;
  }

  /// A friend said where they live, and which of this account's records they hold (`has`): theirs is kept where it is
  /// their own by their key and newer than the one held, and given to the relay, which routes by it; they count as
  /// told up to what they hold; and where they don't hold this account's as it is now, they are told it, once a minute
  /// at most. So a friend who first hears this account's, or one who moved, always ends up holding it, and one on an
  /// app from before is sent it once and no more (found in the review, 2026-11-23).
  void _heardHome(String from, Object? said, Object? has) {
    final had = byId(from);
    if (had == null || had.state == 'blocked') return;
    final rec = HomeRecord.check(said, forId: from, forKey: had.key);
    final held = had.home == null ? null : HomeRecord.check(had.home, forId: from, forKey: had.key, now: DateTime.fromMillisecondsSinceEpoch(had.home!['t'] as int? ?? 0));
    if (rec != null && (held == null || rec.newerThan(held))) {
      var b = had.copyWith(home: rec.toJson());
      // Labelled by where they live now: name@their relay, or the bare name where that is this app's.
      if (had.username.contains('@') || elsewhere(b)) {
        final bare = splitUsername(had.username).name;
        final host = elsewhere(b) ? b.homeHost : '';
        b = Buddy(username: host.isEmpty ? bare : '$bare@$host', id: b.id, key: b.key, name: b.name, bio: b.bio, state: b.state, at: b.at, picture: b.picture, status: b.status, links: b.links, cosmetics: b.cosmetics, home: b.home, banner: b.banner, own: b.own);
      }
      _put(b);
      if (_routed(b)) _homes?.give(rec.toJson());
      unawaited(_save());
    }
    final mine = _homes?.mine;
    if (has is int && _toldFor != null) {
      if (has > (_told[from] ?? 0)) _told[from] = has;
      _keepTold();
    }
    if (mine == null || byId(from)?.state != 'yes' || (has is int && has >= mine.n)) return;
    final now = DateTime.now(), last = _repliedAt[from];
    if (last != null && now.difference(last) < const Duration(minutes: 1)) return;
    _repliedAt[from] = now;
    unawaited(_tellHome(from));
  }

  /// The record [body] carries as `h`, where it is [from]'s own by the key [key], and newer than [had]'s; else null.
  Map<String, Object?>? _homeIn(Map body, String from, String key, Buddy? had) {
    final rec = HomeRecord.check(body['h'], forId: from, forKey: key);
    if (rec == null) return null;
    final held = had?.home == null ? null : HomeRecord.check(had!.home, forId: from, forKey: key, now: DateTime.fromMillisecondsSinceEpoch(had.home!['t'] as int? ?? 0));
    return held == null || rec.newerThan(held) ? rec.toJson() : null;
  }

  /// What the directory says of [username] for the install [id] ([Buddy.check]): `ok`, `other`, `nobody`, or '' where
  /// the relay can't be asked now (or answered about another name: Me.whois).
  Future<String> _lookUp(String username, String id, {bool dial = false}) async => (await _lookUpWhy(username, id, dial: dial)).said;

  /// [_lookUp], and whether the relay refused it as one too many in the hour: then nothing more is looked up of the
  /// app's own accord for a while, the name watch's lookups included ([_lookups]).
  Future<({String said, bool refused})> _lookUpWhy(String username, String id, {bool dial = false}) async {
    try {
      final at = splitUsername(username);
      if (at.relay != null) {
        // A name on another relay: asked of that relay through this app's own; dialled itself only where the person
        // pressed Accept ([dial]), never of this phone's own accord for a stranger's request (lib/net/relay_ask.dart).
        final homes = _homes;
        if (homes == null) return (said: '', refused: false);
        final found = await homes.whois(at.name, at.relay!, dial: dial);
        return (said: found == null ? 'nobody' : (found.id == id ? 'ok' : 'other'), refused: false);
      }
      final found = await _port.whois(tidyHandle(username));
      return (said: found == null ? 'nobody' : (found.id == id ? 'ok' : 'other'), refused: false);
    } catch (e) {
      final refused = LookupBudget.isRefusal(e);
      if (refused) _lookups.refused();
      return (said: '', refused: refused);
    }
  }

  /// When each request, by install and username, last had an answer. The relay answers an account so many lookups an
  /// hour, counted for all its devices together (relay/lib/handles.dart, lookupsAnHour: 120), and strangers' requests
  /// could use them all, so that no request could be accepted and nobody added for an hour (found in review,
  /// 2026-11-23): requests are looked up of the app's own accord within the account's budget, which the name watch
  /// shares and the account's devices share out ([_lookups]: LookupBudget.forRequests an hour on this device), each
  /// request once an hour; past that a request is looked up when Accept is pressed.
  final Map<String, DateTime> _answered = {};

  /// Whether this phone may look up the request [what] (`<id>:<username>`) of its own accord now: counted where it may.
  bool _mayLookUp(String what) {
    final last = _answered[what];
    if (last != null && DateTime.now().difference(last) < const Duration(hours: 1)) return false;
    return _lookups.take();
  }

  /// A request's lookup of this phone's own accord: [_lookUp], within [_mayLookUp]; null where it may not be made now.
  Future<String?> _lookUpOwn(Buddy b) async {
    final what = '${b.id}:${b.username}';
    if (!_mayLookUp(what)) return null;
    final said = await _lookUp(b.username, b.id);
    if (said.isNotEmpty) _answered[what] = DateTime.now();
    return said;
  }

  /// [b] in its place in the list, as it now is.
  void _replace(Buddy b) => all = [for (final o in all) o.id == b.id ? b : o];

  /// Asks the directory again about each request it hasn't said `ok` to ([Buddy.check]), of this phone's own accord and
  /// so within the account's budget ([_mayLookUp]): what it says now is kept with each. None is forgotten on one answer: one whose username
  /// it gives someone else stays, shown so and not to be accepted, until it is declined or the directory says otherwise.
  /// How many changed.
  @visibleForTesting
  Future<int> checkRequests() async {
    if (_remote) return 0;
    var changed = 0;
    for (final b in [for (final b in all) if (b.state == 'invited' && !b.checked) b]) {
      final said = await _lookUpOwn(b);
      final now = byId(b.id);
      if (said == null || said.isEmpty || now == null || now.state != 'invited' || now.username != b.username || now.check == said) continue;
      _replace(now.copyWith(check: said));
      changed++;
    }
    if (changed > 0) await _save();
    return changed;
  }

  /// The friend by username [username] stands for: of those who said yes under it, the one [onePerUsername] picks, which
  /// is the record a conversation with `@username` is (UsernameChats.states). Never one who only asked, or was asked.
  Buddy? standingFor(String username) {
    final name = tidyHandle(username);
    return onePerUsername(friends).where((b) => b.username.toLowerCase() == name).firstOrNull;
  }

  /// Sends each request still unanswered, newer than [askFor], again.
  @visibleForTesting
  Future<int> askAgain() async {
    if (_remote) return 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    final waiting = [for (final b in all) if (b.state == 'asked' && now - b.at < askFor.inMilliseconds) b];
    if (waiting.isEmpty) return 0;
    final ({String id, String key}) me;
    try {
      me = await _port.me();
    } catch (_) {
      return 0;
    }
    var sent = 0;
    for (final b in waiting) {
      try {
        if (await _sendAsk(b, me.key)) sent++;
      } catch (_) {}
    }
    return sent;
  }

  /// Keeps the list on the phone and tells listeners.
  Future<void> _save() async {
    await _port.keep(jsonEncode([for (final b in all) b.toJson()]));
    notifyListeners();
  }

  /// Friends another device of this account has and this one does not, or has as less far along, taken in from the
  /// account's kept copy (lib/account/account.dart takeIn; Matt, 2026-11-25: "messages are still not kept in sync
  /// across all devices, all my devices have different sidebars"). A device learned the account's friends once, as it
  /// signed in: a friend made on another device afterwards was never one here, so what they wrote was dropped here and
  /// their conversation never came with the others. Nobody here is taken out or changed otherwise: a friend ended on
  /// this device stays ended. How many were taken in.
  Future<int> takeFromAccount(List<Object?> friends) async {
    var taken = 0;
    for (final j in friends) {
      final b = Buddy.fromJson(j);
      if (b == null || b.state != 'yes') continue;
      final had = all.where((o) => o.id == b.id).firstOrNull;
      if (had == null) {
        _put(b);
        taken++;
      } else if (had.state == 'asked' || had.state == 'invited') {
        // Asked or asking here, friends there: friends.
        _put(had.copyWith(state: 'yes'));
        taken++;
      }
    }
    if (taken > 0) await _save();
    return taken;
  }

  /// Puts [b] in the list in place of whoever had its id, and keeps their picture.
  void _put(Buddy b) {
    all = [for (final o in all) if (o.id != b.id) o, b];
    ProfilePictures.instance.keep(b.id, b.picture);
  }

  // --- vouches (GMFB-33; lib/friends/vouches.dart) ------------------------------------------------------------------
  //
  // A friend vouches for another with a sealed envelope of kind `vouch` (the signed word, `{"b","f","t","s","x"?}`),
  // which a build from before passes over. The one vouched for keeps it and carries what it holds with its sealed
  // profile (`vo` in `buddy` `yes` and `me`, and `buddy` `vo` alone when it changes), never with a request, which goes
  // in the clear. A profile shows only the vouches of the viewer's own friends, checked against the keys the viewer
  // holds for them.

  Vouches? _vouches;

  /// The vouches given, held and carried, kept where the app keeps its choices (or in memory, for a port without).
  Vouches get vouches => _vouches ??= _across == null ? Vouches.inMemory() : Vouches(read: _across!.recall, write: _across!.remember);

  /// This account's name and key, once [start] asked.
  ({String id, String key})? _me;

  /// Whether vouching is done here: not on a computer that speaks through its phone, where the phone's friends are.
  bool get vouchesHere => !_remote && _port is BuddiesSigner;

  /// This account's vouch for [b], where it gave one that is good now and has not taken it back (on this device or, as
  /// [b]'s profile carries it back, another of this account's).
  bool vouchedFor(Buddy b) => _givenFor(b) != null;

  Vouch? _givenFor(Buddy b) => vouches.givenFor(b.id, forKey: b.key, myKey: _me?.key);

  /// When this account's vouch for [b] runs out, where it gave one that is good now; null otherwise. Vouch for again
  /// renews it for another year.
  DateTime? vouchRunsOut(Buddy b) {
    final v = _givenFor(b);
    return v == null ? null : DateTime.fromMillisecondsSinceEpoch(v.until);
  }

  /// Vouches for [b] (or for this account, where [b] is null) that count here: by this account's own friends, one a
  /// username, each checked against the key held for them.
  List<Buddy> vouchersOf(Buddy? b) {
    final me = _me;
    final id = b?.id ?? me?.id, key = b?.key ?? me?.key;
    if (id == null || key == null) return const [];
    return onePerUsername(vouches.vouchersOf(id, key, friends, id: (f) => f.id, key: (f) => f.key));
  }

  /// Vouches for [b] (or takes this account's vouch back: [on] false), and tells them.
  Future<void> vouch(Buddy b, {bool on = true}) async {
    final signer = _port is BuddiesSigner ? _port as BuddiesSigner : null, me = _me;
    if (_remote || signer == null || me == null) throw MeError('Vouching is done on the device your friends are on.');
    if (byId(b.id)?.state != 'yes') throw MeError('You can vouch only for a friend.');
    final v = await vouches.make(me: me.id, forId: b.id, forKey: b.key, on: on, sign: signer.sign);
    notifyListeners();
    // This account's other devices are told too, so each says the same of who it vouches for.
    unawaited(syncVouches());
    await _port.send(b.id, Envelope(kind: 'vouch', body: v.toJson()));
  }

  /// What this account's devices tell each other of the vouches it gave (GMFB-33: each device kept its own, so a vouch
  /// made on the phone was not known to the Mac): a sealed envelope to the account's own devices, `{"v": [...]}`, every
  /// word this device holds as it was signed ([Vouches.own]), takings back among them; `q` 1 where it asks to be told
  /// what the others hold. Builds from before pass the kind over.
  static const ownKind = 'vouch-mine';

  /// What this account's devices tell each other of its profile (Matt, 2026-11-25: "on my mac i updated my profile
  /// picture and the banner but it didn't sync to my phone"): a part changed ([Me.ownParts]) as `{"m": part, "t":
  /// when, "i": piece, "of": pieces, ...}`, each piece within a packet ([Me.ownPieces]), taken in once all its pieces
  /// are here and newer than this device's ([Me.takeOwn]); or `{"q": {part: when}}`, asking for any part newer than
  /// those. Builds from before pass the kind over.
  static const profileKind = 'profile-mine';

  bool _profileAsked = false;
  final Map<String, Timer> _profileTimers = {};
  final Map<String, DateTime> _profileTold = {};
  DateTime? _profileAskedBack;
  final Map<String, Map<String, Object?>> _profilePieces = {};

  void _ownProfileSoon(String part) {
    _profileTimers[part]?.cancel();
    _profileTimers[part] = Timer(const Duration(seconds: 2), () {
      _profileTimers.remove(part);
      unawaited(tellOwnProfile(part));
    });
  }

  /// Tells this account's other devices [part] of the profile as it is here; true where the routes took every piece.
  @visibleForTesting
  Future<bool> tellOwnProfile(String part) async {
    final port = _port;
    if (_remote || port is! BuddiesMine || _me == null) return false;
    final me = Me.instance, at = me.ownAt(part);
    if (at == 0) return false;
    final pieces = me.ownPieces(part);
    _profileTold[part] = DateTime.now();
    var all = true;
    for (var i = 0; i < pieces.length; i++) {
      try {
        if (!await (port as BuddiesMine).sendMine(Envelope(kind: profileKind, body: {'m': part, 't': at, 'i': i, 'of': pieces.length, ...pieces[i]}))) all = false;
      } catch (_) {
        all = false;
      }
    }
    return all;
  }

  /// Asks this account's other devices for any part of the profile newer than this one's (once a run, a little after
  /// starting, until the routes take it).
  @visibleForTesting
  Future<void> askOwnProfile() async {
    final port = _port;
    if (_remote || port is! BuddiesMine || _me == null) return;
    final me = Me.instance;
    try {
      if (await (port as BuddiesMine).sendMine(Envelope(kind: profileKind, body: {'q': {for (final p in Me.ownParts) p: me.ownAt(p)}}))) _profileAsked = true;
    } catch (_) {}
  }

  void _heardOwnProfile(String from, Map body) {
    final me = _me;
    if (_remote || me == null || from != me.id) return;
    final q = body['q'];
    if (q is Map) {
      var askBack = false;
      for (final part in Me.ownParts) {
        final theirs = q[part] is int ? q[part] as int : 0, mine = Me.instance.ownAt(part);
        if (mine > theirs) {
          // At most once in thirty seconds a part, so two devices never go on answering each other.
          final last = _profileTold[part];
          if (last == null || DateTime.now().difference(last) >= const Duration(seconds: 30)) unawaited(tellOwnProfile(part));
        } else if (theirs > mine) {
          askBack = true;
        }
      }
      // They have something newer and only answer an asking: asked, as rarely.
      final now = DateTime.now();
      if (askBack && (_profileAskedBack == null || now.difference(_profileAskedBack!) >= const Duration(seconds: 30))) {
        _profileAskedBack = now;
        unawaited(askOwnProfile());
      }
      return;
    }
    final part = body['m'], at = body['t'], i = body['i'], of = body['of'];
    if (part is! String || !Me.ownParts.contains(part) || at is! int || i is! int || of is! int || of < 1 || of > 4 || i < 0 || i >= of) return;
    if (at <= Me.instance.ownAt(part)) return;
    final key = '$part/$at';
    final held = _profilePieces[key] ??= <String, Object?>{'_got': <int>{}};
    (held['_got'] as Set<int>).add(i);
    for (final e in body.entries) {
      if (e.key is String && !const {'m', 't', 'i', 'of'}.contains(e.key)) held[e.key as String] = e.value;
    }
    if ((held['_got'] as Set<int>).length < of) {
      // Only the newest few are waited for.
      while (_profilePieces.length > 6) {
        _profilePieces.remove(_profilePieces.keys.first);
      }
      return;
    }
    _profilePieces.remove(key);
    _profilePieces.removeWhere((k, _) => k.startsWith('$part/'));
    Me.instance.takeOwn(part, at, held);
  }

  /// Whether this run has asked the account's other devices what they gave, and when one was last answered.
  bool _ownAsked = false;
  DateTime? _ownAnswered;

  /// Tells this account's other devices the vouches this one gave; with [ask], asks for theirs too (once a run, a
  /// little after starting: a device that was closed heard nothing of what was given meanwhile). The timers call it; a
  /// test calls it itself.
  @visibleForTesting
  Future<void> syncVouches({bool ask = false}) async {
    final port = _port;
    if (_remote || port is! BuddiesMine || _me == null) return;
    final own = vouches.own();
    if (own.isEmpty && !ask) return;
    try {
      final sent = await (port as BuddiesMine).sendMine(Envelope(kind: ownKind, body: {'v': own, if (ask) 'q': 1}));
      if (ask && sent) _ownAsked = true;
    } catch (_) {}
  }

  /// Another device of this account said what it gave: taken where each word is this account's own by its signature
  /// and newer than the one here ([Vouches.tookOwn]). Where it asked and this device holds a word it did not say, or a
  /// newer one, it is told this device's, at most once in thirty seconds; an answer asks nothing, so two devices never
  /// go on answering each other.
  void _heardOwn(String from, Map body) {
    final me = _me;
    if (_remote || me == null || from != me.id) return;
    final said = body['v'];
    final took = vouches.tookOwn(said, me: me.id, myKey: me.key, keyOf: (id) {
      final f = byId(id);
      return f?.state == 'yes' ? f!.key : null;
    });
    if (took) notifyListeners();
    if (body['q'] != 1) return;
    final theirs = <String, int>{
      for (final j in said is List ? said.take(Vouches.ownMost) : const <Object?>[])
        if (j is Map && j['f'] is String && j['t'] is int) j['f'] as String: j['t'] as int,
    };
    if (!vouches.own().any((v) => (theirs[v['f']] ?? 0) < (v['t'] as int))) return;
    final now = DateTime.now();
    if (_ownAnswered != null && now.difference(_ownAnswered!) < const Duration(seconds: 30)) return;
    _ownAnswered = now;
    unawaited(syncVouches());
  }

  /// Whether this account carries the vouches it holds to its friends. Friends are told with the next carrying
  /// ([carryAfter]), with `vh` so they let go of what was carried before.
  Future<void> hideVouches(bool hide) async {
    vouches.setHidden(hide);
    notifyListeners();
    _carrySoon();
  }

  /// How long after what this account holds changes before friends are told, once, whatever changed meanwhile (found
  /// in review, 2026-11-23: each change was sent to every friend at once, so one friend toggling a vouch could fill an
  /// away friend's mailbox on the relay and wake every iPhone). What was last told is kept with the vouches
  /// ([Vouches.lastCarried]), so a carrying the app closed before making is made at its next start.
  final Duration carryAfter;
  Timer? _carrier;

  /// The most of one friend's vouch changes in an hour that make friends be told soon; past that each is still taken,
  /// and friends are told once that hour is up (or with the next carrying anything else makes).
  static const vouchesAnHour = 4;
  final Map<String, List<DateTime>> _vouchesFrom = {};

  void _carrySoon([Duration? after]) {
    _carrier ??= Timer(after ?? carryAfter, () {
      _carrier = null;
      unawaited(carryNow());
    });
  }

  /// What is said of the vouches held, the same for every friend, hashed: what [Vouches.lastCarried] holds.
  String _carryHash() => NetCrypto.hex(NetCrypto.sha256(utf8.encode(jsonEncode({'vo': vouches.carry(), 'vh': vouches.hidden, 'dr': vouches.dropped, 'dt': {for (final e in vouches.droppedTo.entries) e.key: [...e.value]..sort()}}))));

  /// Whether nothing at all is held, given, or dropped: what a first start after the update has, which needs no telling.
  bool get _nothingToCarry => vouches.carry().isEmpty && !vouches.hidden && vouches.dropped.isEmpty;

  /// At [start]: friends are told what this account holds where it changed since they were last told (the app closed
  /// before the carrying was made).
  void _carryIfOwed() {
    final hash = _carryHash();
    if (hash == vouches.lastCarried) return;
    if (vouches.lastCarried == null && _nothingToCarry) {
      vouches.markCarried(hash);
      return;
    }
    if (friends.isNotEmpty) _carrySoon();
  }

  /// Tells every friend what this account now holds, where it isn't what they were last told: one envelope each. The
  /// timer calls it; a test calls it itself.
  @visibleForTesting
  Future<void> carryNow() async {
    _carrier?.cancel();
    _carrier = null;
    final hash = _carryHash();
    if (hash == vouches.lastCarried) return;
    for (final b in friends) {
      try {
        if (await _port.send(b.id, Envelope(kind: 'buddy', body: {'s': 'vo', ..._carryBody(b.id)}))) vouches.carriedTo(b.id);
      } catch (_) {}
    }
    vouches.markCarried(hash);
  }

  /// What a profile says of the vouches held to [friend]: `vo`; `vh` where the person hid them; `vd`, those whose
  /// vouch this account dropped (no longer friends) and when, of the ones [friend] was carried.
  Map<String, Object> _carryBody(String friend) {
    final vd = vouches.droppedFor(friend);
    return {'vo': vouches.carry(), if (vouches.hidden) 'vh': 1, if (vd.isNotEmpty) 'vd': vd};
  }

  /// A friend vouched for this account, or took it back: always taken (newest wins); friends are told soon for at most
  /// [vouchesAnHour] of one friend's changes an hour, and the rest once the hour is up.
  void _heardVouch(String from, Map body) {
    final had = byId(from), me = _me;
    if (had == null || had.state != 'yes' || me == null) return;
    if (!vouches.heard(body, from: from, fromKey: had.key, me: me.id, meKey: me.key)) return;
    notifyListeners();
    final now = DateTime.now();
    final recent = (_vouchesFrom[from] ?? const <DateTime>[]).where((t) => now.difference(t) < const Duration(hours: 1)).toList();
    _vouchesFrom[from] = [...recent, now];
    if (recent.length < vouchesAnHour) return _carrySoon();
    _carrySoon(const Duration(hours: 1) - now.difference(recent.first));
  }

  /// What a friend's sealed profile says they hold (`vo`), where it says it.
  void _heardCarried(Buddy had, Map body) {
    if (!body.containsKey('vo')) return;
    vouches.tookCarried(had.id, body['vo'], hidden: body['vh'] == 1, dropped: body['vd'], friendKey: had.key, keyOf: (id) {
      if (id == _me?.id) return _me!.key;
      final f = byId(id);
      return f?.state == 'yes' ? f!.key : null;
    });
    notifyListeners();
  }

  /// [id] is no longer a friend: their vouch goes, and friends are told with the next carrying.
  void _dropVouches(String id) {
    final held = vouches.held[id]?.on ?? false;
    vouches.forget(id);
    if (held) _carrySoon();
  }

  /// What friends are told of this person in a sealed envelope: [_profile], the links they typed for their profile
  /// (`ol`, GMFB-34; never in a request, which goes in the clear), and the vouches it holds.
  Map<String, Object> _sealedProfile(String friend) => {..._profile(), 'ol': [for (final l in Me.instance.ownLinks) l.toJson()], ..._carryBody(friend)};

  /// The most a sealed profile may be, as the JSON that goes, with the banner picture in it: the hub takes a packet of
  /// 60 KB (HubCarrier.maxPacket), and the envelope, its sealing and forward secrecy's keys need room besides.
  static const profileRoom = 54 * 1024;

  /// A sealed profile for [friend], as step [s] (`yes` or `me`), with this person's banner picture (`bp`, GMFB-34; ''
  /// for none, so a friend lets go of the one before). The two profile pictures can fill most of a packet, so where
  /// the banner would not fit beside them it is left out and named as [after], to go in an envelope of its own
  /// (`buddy` `bn`). A build from before passes over both and draws the ready-made banner chosen.
  ({Map<String, Object> body, String? after}) _toldProfile(String friend, String s) {
    final body = <String, Object>{'s': s, ..._sealedProfile(friend)};
    final banner = Me.instance.banner;
    if (!ProfilePictures.goodBanner(banner)) return (body: {...body, 'bp': ''}, after: null);
    if (jsonEncode(body).length + banner.length + 8 <= profileRoom) return (body: {...body, 'bp': banner}, after: null);
    return (body: body, after: banner);
  }

  /// Tells the friend [id] this person's profile as step [s]; true where the routes took it.
  Future<bool> _tellProfile(String id, String s) async {
    final told = _toldProfile(id, s);
    if (!await _port.send(id, Envelope(kind: 'buddy', body: told.body))) return false;
    vouches.carriedTo(id);
    if (told.after != null) await _port.send(id, Envelope(kind: 'buddy', body: {'s': 'bn', 'bp': told.after!}));
    return true;
  }

  /// What friends are told of this person. The picture and status since 2026-11-19 (`p`, `st`); a build from before
  /// passes over them.
  Map<String, Object> _profile() {
    final me = Me.instance;
    // `p`, the small picture, for builds from before 0.10.4; `pp`, the sharp one shown, for the rest.
    final sharp = me.pictureSharp;
    return {'u': _port.username ?? '', 'n': _port.displayName, 'b': _port.bio, if (me.picture.isNotEmpty) 'p': me.picture, if (sharp != me.picture) 'pp': sharp, 'st': me.status, 'l': me.shareLinks ? me.links : const <String, String>{}, 'cx': me.cosmetics.toJson()};
  }

  /// A picture and status said in [body], where it says them: null for each it does not (a build from before).
  @visibleForTesting
  static ({String? picture, String? status, Map<String, String>? links, Cosmetics? cosmetics, String? banner, List<OwnLink>? own}) saidOf(Map body) => _said(body);

  static ({String? picture, String? status, Map<String, String>? links, Cosmetics? cosmetics, String? banner, List<OwnLink>? own}) _said(Map body) {
    final pp = body['pp'], p = body['p'];
    final picture = pp is String && pp.isNotEmpty && pp.length <= ProfilePictures.most ? pp : p;
    return (picture: picture is String && picture.length <= ProfilePictures.most ? picture : (body.containsKey('st') ? '' : null), status: body['st'] is String ? body['st'] as String : null, links: Buddy._linksOf(body['l']), cosmetics: Cosmetics.fromJson(body['cx']), banner: Buddy._bannerOf(body['bp']), own: OwnLink.listOf(body['ol']));
  }

  /// Who [username] is, as the add-friend drawer shows it while it is typed: nobody, this install itself, or someone
  /// (lib/ui/add_friend_drawer.dart). Asks the same server [add] asks.
  Future<BuddyLookup> lookup(String username) async {
    if (_remote) return BuddyLookup.values.asNameMap()['${(await _ask({'op': 'lookup', 'u': username}))['found']}'] ?? BuddyLookup.nobody;
    final typed = splitUsername(username);
    final homes = _homes;
    final String? foundId;
    if (typed.relay != null && !(homes?.isHere(typed.relay!) ?? false)) {
      // On another relay: nobody is asked while a name is typed (each look would be a question put to a server of
      // someone else's choosing, and a host half typed is another server): that relay is asked when the person asks
      // to add them (found in the review, 2026-11-23).
      if (homes == null || !goodAddress(username)) return BuddyLookup.nobody;
      if (!dialableRelayHost(typed.relay!)) return BuddyLookup.nobody;
      return BuddyLookup.elsewhere;
    } else {
      foundId = (await _port.whois(typed.name))?.id;
    }
    if (foundId == null) return BuddyLookup.nobody;
    if (foundId == (await _port.me()).id) return BuddyLookup.you;
    return BuddyLookup.someone;
  }

  /// Asks [username] to be friends. Throws a [MeError] where nobody has that username, or it is this install's.
  ///
  /// [keyPrefix], from an add-me link (lib/friends/add_link.dart): the first hex digits of the account name the person
  /// who shared it has. The relay's answer is refused where its key doesn't make a name that begins so: it gave the
  /// username to someone else, and nothing is kept or sent.
  Future<Buddy> add(String username, {String? keyPrefix}) async {
    if (_remote) return Buddy.fromJson((await _ask({'op': 'add', 'u': username, 'kp': ?keyPrefix}))['buddy'])!;
    final typed = splitUsername(username);
    var name = typed.name;
    if (_port.username == null) throw MeError('Choose your own username first.');
    final homes = _homes;
    final String id, key;
    Map<String, Object?>? home;
    // Whether this relay's own directory gave the answer (not another relay's): only then is it the name watch's.
    var askedHere = false;
    if (typed.relay != null && !(homes?.isHere(typed.relay!) ?? false)) {
      // Someone on another relay (`maya@relay.example`): asked of that relay, and kept with where they live.
      final host = typed.relay!;
      if (!goodAddress(username)) throw MeError('That isn\'t a username on another relay. It looks like maya@relay.example.');
      if (homes == null) throw MeError('People on other relays can\'t be added from here.');
      final FoundOnRelay? found;
      try {
        found = await homes.whois(name, host);
      } on HomeError catch (e) {
        throw MeError(e.message);
      }
      if (found == null) throw MeError('Nobody has the username @$name on $host.');
      id = found.id;
      key = found.key;
      askedHere = found.here;
      final rec = found.home;
      if (!found.here && (rec == null || !homes.livesHere(rec))) {
        // Without their record no relay knows where to pass a packet for them; and a relay that passes nothing on
        // reaches nobody elsewhere, whatever their app.
        if (!found.talks) throw MeError('@$name is on $host, which doesn\'t pass messages to other relays.');
        if (rec == null) throw MeError('@$name@$host can\'t be reached from another relay yet. They need a newer version of Uplink.');
        name = '$name@$host';
      }
      home = rec?.toJson();
    } else {
      final found = await _port.whois(name);
      if (found == null) throw MeError('Nobody has the username @$name.');
      id = found.id;
      key = found.key;
      askedHere = true;
    }
    if (keyPrefix != null && !keyMatches((id: id, key: key), keyPrefix)) {
      throw MeError('The relay gave @$name to a different key than the link names, so nothing was sent. Ask them for their link again, or check their username with them.');
    }
    final me = await _port.me();
    if (id == me.id) throw MeError('That\'s you.');
    final had = byId(id);
    // The relay named their key under this username just now: what the name watch holds its answers to from here
    // (lib/net/name_watch.dart), so a later answer naming another account is worth saying. Only this relay's own
    // directory's answer: a name on another relay is that relay's to give.
    if (askedHere && Buddies.keyMatches((id: id, key: key), id)) NameWatch.instance?.confirmed(id, name);
    if (had != null && had.state == 'yes') return had;
    // They asked first: this is a yes, under the username the directory just gave for them.
    if (had != null && had.state == 'invited') return accept(had.copyWith(username: name, check: 'ok', home: _newerOf(home, had.home)));
    final b = Buddy(username: name, id: id, key: key, state: 'asked', at: DateTime.now().millisecondsSinceEpoch, home: _newerOf(home, had?.home), check: 'ok');
    _put(b);
    await _save();
    // The relay is told where they live before the request goes, so it can pass it on.
    if (b.home != null) homes?.give(b.home!);
    await _sendAsk(b, me.key);
    return b;
  }

  /// Sends [b] the friend request: this account's key, how it shows itself, and its own home record, so the answer
  /// can find its way back from another relay. Where [b] lives on another relay, whether this app's relay passed it
  /// on is kept ([unreached]).
  Future<bool> _sendAsk(Buddy b, String myKey) async {
    final mine = _homes?.mine;
    final sent = await _port.send(b.id, Envelope(kind: 'hello', body: {'buddy': 'ask', 'k': myKey, ..._profile(), 'h': ?mine?.toJson()}), sealed: false);
    if (elsewhere(b) && !(sent && (_across?.passedOn(b.id) ?? false))) {
      if (_unreached.add(b.id)) notifyListeners();
    } else if (_unreached.remove(b.id)) {
      notifyListeners();
    }
    return sent;
  }

  /// Whether [found] (the relay's answer for a username) is the key an add-me link names by [keyPrefix]: the account
  /// name is the one its key makes, and begins with those digits.
  static bool keyMatches(({String id, String key}) found, String keyPrefix) {
    final want = keyPrefix.toLowerCase();
    if (want.isEmpty || !found.id.startsWith(want)) return false;
    try {
      return NetCrypto.idOf(base64Decode(found.key)) == found.id;
    } catch (_) {
      return false;
    }
  }

  /// Says yes to [b]. A request is said yes to only where the relay's directory says its username is its sender's
  /// ([Buddy.check]), asked now if it hasn't said so, whatever this phone's own lookups an hour have come to. Where it
  /// doesn't, a [MeError] says why, and the request stays as it is, with what the directory said: it is never forgotten on
  /// one answer (found in review, 2026-11-23).
  Future<Buddy> accept(Buddy b) async {
    if (_remote) return Buddy.fromJson((await _ask({'op': 'accept', 'id': b.id}))['buddy'])!;
    var it = b;
    if (b.state == 'invited' && !b.checked) {
      final (:said, :refused) = await _lookUpWhy(b.username, b.id, dial: true);
      if (said != 'ok') {
        final now = byId(b.id);
        if (said.isNotEmpty && now != null && now.state == 'invited' && now.username == b.username && now.check != said) {
          _replace(now.copyWith(check: said));
          await _save();
        }
        throw MeError(switch (said) {
          'other' => 'The relay gives @${b.username} to someone else, so this request didn\'t come from them. It stays until you decline it.',
          'nobody' => 'The relay doesn\'t know the username @${b.username}, so this request can\'t be checked. It waits here.',
          _ when refused => busyWords(b.username, _lookups.freesBy),
          _ => '@${b.username} can\'t be checked with the relay server right now, so the request waits until it can be. Try again once you\'re connected.',
        });
      }
      it = b.copyWith(check: 'ok');
    }
    // The relay's directory says the username is theirs (just now, or when it was last asked): what the name watch holds
    // its answers to from here (lib/net/name_watch.dart), under the name looked up. Not someone on another relay
    // (name@relay): this relay's directory isn't theirs.
    if (b.state == 'invited' && splitUsername(it.username).relay == null) NameWatch.instance?.confirmed(b.id, tidyHandle(it.username));
    final yes = it.copyWith(state: 'yes');
    _put(yes);
    await _save();
    // Their record is given the relay now, just before the yes, so the yes is passed on to theirs.
    if (yes.home != null) _homes?.give(yes.home!);
    await _tellProfile(b.id, 'yes');
    // Friends now: they are told where this account lives.
    await _tellHome(b.id);
    return yes;
  }

  /// What Accept says where the relay refused the lookup as one too many in the hour: the relay's hourly limit, and by
  /// when one frees up at the latest ([LookupBudget.freesBy], ms; null for within the hour), never to connect.
  @visibleForTesting
  static String busyWords(String username, int? freesBy, {DateTime? now}) {
    final left = freesBy == null ? 60 : ((freesBy - (now ?? DateTime.now()).millisecondsSinceEpoch) / 60000).ceil();
    final within = left >= 60 ? 'within the hour' : (left <= 1 ? 'within a minute' : 'within $left minutes');
    return 'The relay answers only so many lookups an hour, and this account has used them up for now, so @$username can\'t be checked yet. One frees up $within: try Accept again then. The request waits here.';
  }

  Future<void> decline(Buddy b) async {
    if (_remote) {
      await _ask({'op': 'decline', 'id': b.id});
      return;
    }
    all = [for (final o in all) if (o.id != b.id) o];
    _homes?.forget(b.id);
    _dropVouches(b.id);
    await _save();
    await _port.send(b.id, Envelope(kind: 'buddy', body: {'s': 'no'}));
  }

  /// No longer friends: removed here, and they are told.
  Future<void> remove(Buddy b) async {
    if (_remote) {
      await _ask({'op': 'remove', 'id': b.id});
      return;
    }
    await _port.send(b.id, Envelope(kind: 'buddy', body: {'s': 'end'}));
    all = [for (final o in all) if (o.id != b.id) o];
    _homes?.forget(b.id);
    _dropVouches(b.id);
    _unreached.remove(b.id);
    await _save();
  }

  /// Tells every friend this phone's name and line, after they changed.
  Future<void> shareProfile() async {
    if (_remote) {
      await _ask({'op': 'share'});
      return;
    }
    for (final b in friends) {
      await _tellProfile(b.id, 'me');
    }
  }

  /// Tells every friend what this person is playing ([game]), or that they are not (null): lib/games/game_activity.dart.
  /// A small envelope of its own, so a game starting doesn't send the whole profile, picture and all.
  Future<void> sayActivity(GameActivity? game) async {
    if (_remote) {
      await _ask({'op': 'ga', 'ga': game?.toJson()});
      return;
    }
    for (final b in friends) {
      await _port.send(b.id, Envelope(kind: 'buddy', body: {'s': 'ga', if (game != null) 'ga': game.toJson()}));
    }
  }

  /// A friend request from someone not yet a peer, which comes in the clear as a greeting: checked against the key
  /// the hub knows them by before anything is kept or answered.
  Future<void> _greeting(String from, Envelope e) async {
    if (e.body['buddy'] != 'ask') return;
    final key = e.body['k'], username = e.body['u'];
    if (key is! String || username is! String || !Me.goodUsername(username)) return;
    // The key must be the one the hub knows this name by: nobody asks in someone else's name.
    try {
      if (NetCrypto.idOf(base64Decode(key)) != from) return;
    } catch (_) {
      return;
    }
    final had = byId(from);
    // Blocked: their friend requests go nowhere.
    if (had?.state == 'blocked') return;
    final name = '${e.body['n'] ?? ''}', bio = '${e.body['b'] ?? ''}';
    final said = _said(e.body);
    // Where they live, as they signed it: the relay is given it before anything is answered, so the answer is passed
    // on to theirs.
    final home = _homeIn(e.body, from, key, had);
    // Given the relay only for a friend or one this account asked: a stranger's record waits for a yes.
    if (home != null && had != null && _routed(had)) _homes?.give(home);
    if (had?.state == 'yes') {
      // Asked again by a friend already: our yes was lost on its way (askAgain). Said again.
      if (home != null) {
        _put(had!.copyWith(home: home));
        unawaited(_save());
      }
      unawaited(_tellProfile(from, 'yes').then((_) {}, onError: (_) {}));
      return;
    }
    if (had?.state == 'asked') {
      // Both asked: friends, under the username this phone looked up as it asked.
      unawaited(accept(had!.copyWith(name: name, bio: bio, picture: said.picture, status: said.status, links: said.links, cosmetics: said.cosmetics, home: home)).then((_) {}, onError: (_) {}));
      return;
    }
    // A request names its own username, and anyone can send one: a new one is not kept where the relay's directory gives
    // that username to another install (found in review, 2026-11-23: one that named itself "maya", accepted, took what
    // was written to @maya). It is looked up of this phone's own accord, so once an hour for each request and within the
    // hour's lookups ([_lookUpOwn]). Not looked up, or where the relay can't be asked or knows no such name, it is kept as
    // not checked, says so, and is asked about again (checkRequests), or when Accept is pressed.
    // Someone on another relay is checked, and kept, as name@relay, by the relay their own record names.
    final probe = Buddy(username: '', id: from, key: key, home: home ?? had?.home);
    final host = elsewhere(probe) ? probe.homeHost : '';
    final claimed = host.isEmpty ? tidyHandle(username) : '${tidyHandle(username)}@$host';
    var check = had?.state == 'invited' && had!.username == claimed ? had.check : '';
    if (check != 'ok') {
      final dir = await _lookUpOwn(Buddy(username: claimed, id: from, key: key));
      // Answered meanwhile (accepted, blocked, or asked from here): that stands.
      final now = byId(from);
      if (now != null && now.state != 'invited') return;
      if (dir == 'other') {
        // A new request under someone else's username is not kept; one kept already under it stays, shown so: none is
        // forgotten on one answer.
        if (now == null || now.username != claimed) return;
        check = 'other';
      } else if (dir != null && dir.isNotEmpty) {
        check = dir;
      }
    }
    // A request new to this phone: the friend request's sound (lib/sounds.dart), once.
    if (byId(from)?.state != 'invited') Sounds.instance.play(UiSound.friendRequest);
    _put(Buddy(username: claimed, id: from, key: key, name: name, bio: bio, state: 'invited', at: DateTime.now().millisecondsSinceEpoch, picture: said.picture ?? '', status: said.status ?? '', links: said.links ?? const {}, cosmetics: said.cosmetics ?? Cosmetics.none, home: home ?? had?.home, check: check));
    unawaited(_save());
  }

  /// A sealed `buddy` envelope from someone on the list: their yes, no or end, a changed profile, or their game.
  void _sealed(String from, Envelope e) {
    // Where a friend lives, as they signed it (kind `home`).
    if (e.kind == 'home') return _heardHome(from, e.body['rec'], e.body['has']);
    // A friend's vouch for this account, or its taking back (lib/friends/vouches.dart).
    if (e.kind == 'vouch') return _heardVouch(from, e.body);
    // What another device of this account gave (GMFB-33).
    if (e.kind == ownKind) return _heardOwn(from, e.body);
    // This account's profile as another of its devices has it.
    if (e.kind == profileKind) return _heardOwnProfile(from, e.body);
    if (e.kind != 'buddy') return;
    final had = byId(from);
    if (had == null || had.state == 'blocked') return;
    final name = e.body['n'] is String ? e.body['n'] as String : null, bio = e.body['b'] is String ? e.body['b'] as String : null;
    final said = _said(e.body);
    // The username they say they go by now, in their own sealed profile: where it isn't the one they were added under,
    // the name watch looks it up, and asks about it from then on where the relay names their key for it (they changed
    // it, and their old one may be anyone's now). Not for a friend on another relay: their username is that relay's.
    final u = e.body['u'];
    if ((e.body['s'] == 'me' || e.body['s'] == 'yes') && u is String && Me.goodUsername(u) && tidyHandle(u) != had.username && splitUsername(had.username).relay == null && !elsewhere(had)) NameWatch.instance?.saidName(from, u);
    switch (e.body['s']) {
      case 'yes':
        if (had.state == 'asked') Sounds.instance.play(UiSound.friendAccepted);
        if (had.state == 'asked' || had.state == 'yes') {
          _put(had.copyWith(state: 'yes', name: name, bio: bio, picture: said.picture, status: said.status, links: said.links, cosmetics: said.cosmetics, banner: said.banner, own: said.own));
          _heardCarried(had, e.body);
        }
        // Friends now: they are told where this account lives (they heard it with the request; again costs little).
        if (had.state == 'asked') {
          _unreached.remove(from);
          unawaited(_tellHome(from));
        }
      case 'me':
        if (had.state == 'yes') {
          _put(had.copyWith(name: name, bio: bio, picture: said.picture, status: said.status, links: said.links, cosmetics: said.cosmetics, banner: said.banner, own: said.own));
          _heardCarried(had, e.body);
        }
      case 'bn':
        // A friend's banner picture, where it had no room beside their pictures in the profile (GMFB-34).
        if (had.state != 'yes' || said.banner == null) return;
        _put(had.copyWith(banner: said.banner));
      case 'vo':
        // The vouches a friend holds, changed: kept apart from the list, which the phone reads its keys from.
        if (had.state == 'yes') _heardCarried(had, e.body);
        return;
      case 'ga':
        // What a friend is playing, or that they stopped: kept in memory, never with the list.
        if (had.state == 'yes') GameActivities.instance.heard(from, e.body['ga']);
        return;
      case 'no':
      case 'end':
        GameActivities.instance.heard(from, null);
        all = [for (final o in all) if (o.id != from) o];
        _homes?.forget(from);
        _dropVouches(from);
        _unreached.remove(from);
      default:
        return;
    }
    unawaited(_save());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _again?.cancel();
    _teller?.cancel();
    _carrier?.cancel();
    _across?.homesChanged.removeListener(_homesChanged);
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }
}

/// The port in the app: the routes ([Net]) and their hub, followed as they start again.
class _AppBuddiesPort implements BuddiesPort, BuddiesAcross, BuddiesSigner, BuddiesMine {
  _AppBuddiesPort() {
    Net.instance.listen((r) => _in.add((from: r.peer.id, envelope: r.envelope)));
    Net.instance.addListener(_follow);
    _follow();
  }

  /// Tells when the routes' [Homes] is another one, or this account's record changed.
  final _homesChanged = ValueNotifier<int>(0);
  Homes? _homes;
  void _homeMoved() => _homesChanged.value++;

  @override
  Homes? get homes => Net.instance.homes;
  @override
  Listenable get homesChanged => _homesChanged;
  @override
  bool passedOn(String id) => Net.instance.hub?.passedOn(id) ?? false;
  @override
  String? refusedWhy(String id) => Net.instance.hub?.refusedWhy[id];
  @override
  String recall(String key) => Net.instance.recall(key);
  @override
  void remember(String key, String value) => Net.instance.remember(key, value);

  final _in = StreamController<({String from, Envelope envelope})>.broadcast();
  final _hellos = StreamController<({String from, Envelope envelope})>.broadcast();
  Switchboard? _board;
  StreamSubscription<Object?>? _boardSub;

  /// Listens to the switchboard's strangers (greetings in the clear), and again each time the routes are set up anew.
  void _follow() {
    final homes = Net.instance.homes;
    if (!identical(homes, _homes)) {
      _homes?.removeListener(_homeMoved);
      _homes = homes;
      homes?.addListener(_homeMoved);
      _homeMoved();
    }
    final board = Net.instance.board;
    if (identical(board, _board)) return;
    _boardSub?.cancel();
    _board = board;
    _boardSub = board?.strangers.listen((s) => _hellos.add((from: s.from, envelope: s.envelope)));
  }

  @override
  Future<({String id, String key})> me() async {
    final m = await Sms.instance.netIdentity();
    return (id: m.id, key: base64Encode(m.key));
  }

  @override
  Future<Uint8List> sign(List<int> message) => Sms.instance.netSign(message);

  @override
  String? get username => Me.instance.username;
  @override
  String get displayName => Me.instance.displayName;
  @override
  String get bio => Me.instance.bio;
  @override
  Future<({String id, String key})?> whois(String username) => Me.instance.whois(username);

  @override
  Future<void> keep(String json) async {
    await Sms.instance.buddiesKeep(json);
    await Net.instance.refresh();
  }

  @override
  Future<String> kept() => Sms.instance.buddiesKept();

  @override
  Future<bool> send(String id, Envelope envelope, {bool sealed = true}) async {
    final board = Net.instance.board;
    if (board == null) return false;
    final peer = Net.instance.byId(id) ?? Peer(id: id);
    final d = await board.send(peer, envelope, sealed: sealed, only: const {'hub'});
    return d.sent;
  }

  /// To the account's own other devices, as a message's copy goes to them (lib/friends/friends.dart, sendMine): by the
  /// relay, and straight to one that is linked.
  @override
  Future<bool> sendMine(Envelope envelope) async {
    final board = Net.instance.board;
    final me = await Net.instance.mine();
    if (board == null || me == null) return false;
    return (await board.send(me, envelope, only: const {'hub', 'p2p', 'lan'})).sent;
  }

  @override
  Stream<({String from, Envelope envelope})> get received => _in.stream;
  @override
  Stream<({String from, Envelope envelope})> get greetings => _hellos.stream;
}
