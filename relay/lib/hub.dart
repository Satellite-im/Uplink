import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'accounts.dart';
import 'federation.dart';
import 'handles.dart';
import 'held_store.dart';
import 'invites.dart';
import 'kept_log.dart';
import 'invite_words.dart';
import 'pushes.dart';
import 'turn.dart';
import 'p256.dart';
import 'sha256.dart';
import 'ws_door.dart';

/// The hub: where two people's apps find each other through this server (Matt, 2026-11-14: "implement a full relay
/// system for the app that's replacable and swappable so that for right now we can use our servers to negotiate
/// calls through the app, video chats"). It is one of the app's routes (lib/net/hub_carrier.dart in the app), made
/// to be taken out and a peer-to-peer one put in its place: it holds no account, no name and no number.
///
/// - **Who someone is.** A key pair made on their phone. Their name here is the first 16 bytes of the SHA-256 of
///   the public key, in hex. To connect they sign a number the hub has just made up, so only the holder of the
///   private key connects under that name. One connection per name: a newer one replaces the older.
/// - **A packet to someone** is passed to them if they are connected. If not it is **held** (at most
///   [mailboxFrames] and [mailboxBytes] for one person, [heldBytes] for everyone together, for [holdFor]) and
///   handed over when they next connect. The sender is told which happened. Held packets live in memory: a restart
///   of the hub loses them, and the app's own routes are what a sender falls back on (lib/net/switchboard.dart).
///   Unless its keeper switched on [keepHeld]: then they, and what rooms keep, are on the disk too, still sealed, and
///   a restart loses at most its last moments (held_store.dart).
///   No more than [maxConnections] are connected at once.
/// - **Who is here.** A connection may ask to be told when some names come and go (`watch`), and whether each is using
///   the app or has put it away, and when they were last there (Matt, 2026-11-17: "Do the server change in order to get
///   presense sensing working ... for users who have signed up for a username and are part of our own system"). An app
///   says `{"away": true}` as it goes to the background and `{"away": false}` as it comes back; watchers are told
///   `{"away": id, "is": bool, "at": ms}`, a going is `{"went": id, "at": ms}` (when they were last using it), and
///   the answer to `watch` carries `away` (those here but away) and `seen` (when each not here was last there). Kept
///   in memory only, for at most [maxSeen] names: a restart forgets when anyone was last seen.
///   Since GMFB-34 a person may also choose how they are shown (`{"mode": "online" | "busy" | "invisible"}`, said by
///   any of their devices, held while one is here): busy is told as `{"busy": id, "is": bool}` and listed in the
///   answer to `watch` (`busy`); invisible is shown to watchers as gone (a `went`, no `came`, not in `here`, and when
///   they were last seen is not moved on while they are). An app from before passes over `busy` and never says a mode.
/// - **Looking at a room** without joining it (`look`, with its token): told who is in it, now and as that changes. A
///   voice channel's list, showing who is connected before you jump in.
/// - **Rooms** (a voice room, a group): named by 32 hex digits with a token of 64, both made by its members from a
///   key only they hold; the first to name a room sets its token. Whoever holds the token may join and leave at any
///   time, is told who is in it, and what one member sends to the room goes to the others. A room nobody is in is
///   forgotten.
/// - **Read-only rooms** (Matt, 2026-11-20: "read only channels for system messages and admin / moderation
///   announcements"): a circle's read-only space has a room whose name is made from the circle owner's public key
///   ([anchoredName]), joined with that key and what makes the name (`ro` in the join), so the hub can check the room
///   is that owner's and nobody else's. In it only the owner and the admins the owner signed may post: the admin list
///   is the circle's own (its generation signed by the owner, as the app checks it: lib/circles/circle.dart), handed
///   over by any member and kept at its highest generation. Anyone else's packet the hub would keep is refused, and
///   anything else they send goes to the writers alone, so a changed app can't put words in front of the other
///   members. Such rooms are apart from ordinary ones of the same name, so joining without `ro` never reaches one.
///   Reactions ([toRoomReaction]) are the exception: anyone in the room may react, as a packet too small to be a post.
/// - **What it can see:** which names talk to which, when, and how much. Never what: packets are sealed by the apps
///   with keys the hub never has. It logs no addresses.
/// - **What it does not carry:** a call's sound and picture. Those go between the phones directly (or through a
///   media relay); the hub carries only what sets a call up.
class Hub {
  Hub({DateTime Function()? now, this.verbose = false, Random? random, this.heldBytes = 96 << 20, this.maxConnections = 20000, this.handles, this.pushes, this.invites, this.accounts, this.words, this.turn = const TurnConfig(), List<String> helpers = const [], this.federation, Iterable<String> names = const [], this.dataDir, this.maxSignsV2 = 200000, this.newV2AnHour = 30, this.newV2AnHourAll = 5000, WireBudget? wire, this.oldAppHold = const Duration(minutes: 2), this.heldRefusalsMost = 1000, this.keepHeld = false, this.roomKeepBytes = 256 * 1024 * 1024, String? pass, String? passSalt, this.passGuessesFree = 5, this.passWaitFirst = const Duration(minutes: 1), this.passWaitMost = const Duration(hours: 1), this.passGuessesAll = 200, this.hosted = false, this.trustsProxy = true})
      : _now = now ?? DateTime.now,
        _started = (now ?? DateTime.now)(),
        _random = random ?? Random.secure(),
        _helpers = linkHelpers(helpers),
        names = hubNames(names),
        wire = wire ?? WireBudget.shared,
        _pass = pass == null || pass.isEmpty ? null : pass,
        _passSaltGiven = passSalt {
    federation?.bind(deliver: deliver, isHere: _isHere, knows: _knows, ownNumber: _nonces.contains, handles: handles);
  }

  // --- a pass phrase (a relay hosted from the app: the app's lib/relay_host) ------------------------------------------

  /// The pass phrase its keeper set; null where none is, and then nothing here is said or asked: the hello and the
  /// sign-in are as they always were. Set, the hello says so (`"pass": true`, with this relay's [passSalt] as `"salt"`),
  /// and a sign-in, a look (`peek`) and everything after it are taken only with `"pass"`: [passProof] for this
  /// connection's number and the install signing in. Another relay's hello (`"fed": 1`) is not asked for it: whether
  /// relays link is federation's own choice (federation.dart). Nor is a connection [attach]ed as the keeper's own.
  final String? _pass;
  final String? _passSaltGiven;

  /// What an app must prove it knows ([passKeyOf] of the phrase and [passSalt]), made the first time it is wanted.
  late final List<int>? _passKey = _pass == null ? null : passKeyOf(_pass, passSalt);

  /// Whether this hub asks for a pass phrase.
  bool get asksPass => _pass != null;

  /// What the pass phrase's key is salted with here, said in the hello: the salt given, else this relay's own name
  /// (federation's, where it has one), else sixteen random bytes made as it starts. Each relay its own, so a list of
  /// likely phrases made into keys once is worth nothing against another relay (found in review, 2026-11-23: every
  /// relay was salted with the same words, so the slow part could be paid once for all of them).
  late final String passSalt = _passSaltGiven ?? (federation?.on == true ? federation!.id : hexOf([for (var i = 0; i < 16; i++) _random.nextInt(256)]));

  /// Whether [salt] may be one: 1 to 64 lowercase letters and digits.
  static bool saltOk(Object? salt) => salt is String && RegExp(r'^[0-9a-z]{1,64}$').hasMatch(salt);

  /// What the pass phrase is made into, once, by the hub and by an app alike: PBKDF2 with HMAC-SHA256 over [passWords],
  /// a space and the relay's [salt] as its salt, [passRounds] rounds, 32 bytes. The proof sent over a local network can
  /// be seen there, and a phrase tried against it as fast as this allows: so it is slow to make, a long phrase is what
  /// stands in the way, and the salt makes each relay's guesses its own work.
  static List<int> passKeyOf(String phrase, String salt) => pbkdf2Sha256(utf8.encode(phrase), utf8.encode('$passWords $salt'), passRounds);

  /// PBKDF2 (RFC 8018) with HMAC-SHA256, its first 32 bytes: what [passKeyOf] makes a pass phrase into.
  static List<int> pbkdf2Sha256(List<int> password, List<int> salt, int rounds) {
    var u = hmacSha256(password, [...salt, 0, 0, 0, 1]);
    final out = Uint8List.fromList(u);
    for (var i = 1; i < rounds; i++) {
      u = hmacSha256(password, u);
      for (var j = 0; j < out.length; j++) {
        out[j] ^= u[j];
      }
    }
    return out;
  }

  static const passWords = 'ghost-hub pass v2';
  static const passRounds = 20000;

  /// What an app says in its hello to a hub that asks for a pass phrase (`"pass"`, in hex): HMAC-SHA256 under [key]
  /// ([passKeyOf]) over [passWords], a space, the hub's number for this connection and the install's name (16 bytes).
  /// Good for that connection and that install alone: nothing seen of it can be said again anywhere, or by anyone else.
  static List<int> passProof(List<int> key, List<int> nonce, String id) => hmacSha256(key, [...utf8.encode('$passWords '), ...nonce, ..._unhex(id)]);

  /// Wrong (or missing-and-wrong) pass phrases cost whoever gives them, never everyone (found in review, 2026-11-23: a
  /// count for everyone, 200 an hour, let a stranger with free node ids shut every one out, the keeper's own app too):
  ///
  /// - **Each place** ([placeOf]: a network address; over Direct the node it came from) may give [passGuessesFree]
  ///   wrong ones; after that each try waits [passWaitFirst], doubled with each wrong one, at most [passWaitMost]. A
  ///   place is forgotten an hour after it may try again.
  /// - **Strangers together** (installs that have never given this phrase here) may give [passGuessesAll] wrong ones in
  ///   an hour; past that a stranger is refused until the hour is out, its proof not looked at, so new node ids buy no
  ///   more guesses than that. An install that has given the right phrase here before ([_passKnown], kept in the
  ///   folder with a tag of the key, so a new phrase starts it again) is still looked at: those who use the relay are
  ///   never shut out by a stranger, only newcomers for a while.
  /// - **The keeper's own app**, in memory ([attach] with `own`), is never asked.
  ///
  /// A refusal says `"pass": "busy"` and, in `"wait"`, the seconds until that try would be looked at.
  final int passGuessesFree, passGuessesAll;
  final Duration passWaitFirst, passWaitMost;
  final LinkedHashMap<String, ({int last, int n})> _passWrong = LinkedHashMap();
  ({int from, int n}) _passWrongAll = (from: 0, n: 0);
  final LinkedHashMap<String, bool> _passKnown = LinkedHashMap();
  static const _passPlaces = 10000, _passKnownMost = 10000;

  /// Where the installs that gave the right phrase are kept (`hub-pass.json`), each with [_passTag].
  late final KeptLog? _passLog = dataDir == null || _pass == null ? null : KeptLog(File('${dataDir!.path}/hub-pass.json'));
  Timer? _passSaver;

  /// Eight bytes that say which key an install was known under, and nothing of the key.
  late final String _passTag = hexOf(hmacSha256(_passKey!, utf8.encode('known')).sublist(0, 8));

  /// Whether the install [id] has given the right phrase here, for a test.
  bool passKnows(String id) => _passKnown.containsKey(id);

  /// How long a place that has given [n] wrong ones waits before its next is looked at, in milliseconds.
  int _passWaitAfter(int n) => n < passGuessesFree ? 0 : min(passWaitFirst.inMilliseconds * (1 << min(n - passGuessesFree, 20)), passWaitMost.inMilliseconds);

  /// Milliseconds until a pass phrase from the install [id] at [from] is looked at; null where it is now. [signed] says
  /// whether its signature holds, asked only where it is known and strangers have spent theirs.
  int? _passWait(String from, String id, bool Function() signed) {
    final now = _now().millisecondsSinceEpoch, hour = const Duration(hours: 1).inMilliseconds;
    if (now - _passWrongAll.from >= hour) _passWrongAll = (from: now, n: 0);
    final mine = _passWrong[from];
    if (mine != null) {
      final until = mine.last + _passWaitAfter(mine.n);
      if (now >= until + hour) {
        _passWrong.remove(from);
      } else if (now < until) {
        return until - now;
      }
    }
    if (_passWrongAll.n >= passGuessesAll && !(_passKnown.containsKey(id) && signed())) return max(1, _passWrongAll.from + hour - now);
    return null;
  }

  void _passWasWrong(String from) {
    final now = _now().millisecondsSinceEpoch;
    _passWrongAll = (from: _passWrongAll.from == 0 ? now : _passWrongAll.from, n: _passWrongAll.n + 1);
    final mine = _passWrong.remove(from);
    _passWrong[from] = (last: now, n: (mine?.n ?? 0) + 1);
    while (_passWrong.length > _passPlaces) {
      _passWrong.remove(_passWrong.keys.first);
    }
  }

  /// The install [id] gave the right phrase: kept as one who uses this relay.
  void _passWasRight(String id) {
    final had = _passKnown.remove(id) != null;
    _passKnown[id] = true;
    while (_passKnown.length > _passKnownMost) {
      final oldest = _passKnown.keys.first;
      _passKnown.remove(oldest);
      _passLog?.remove(oldest);
    }
    if (had) return;
    _passLog?.set(id, _passTag);
    if (_passLog != null) _passSaver ??= Timer(const Duration(seconds: 2), _savePass);
  }

  void _loadPass() {
    final log = _passLog;
    if (log == null) return;
    for (final e in log.load().entries) {
      if (_hex(e.key, 32) && e.value == _passTag) _passKnown[e.key] = true;
    }
    while (_passKnown.length > _passKnownMost) {
      _passKnown.remove(_passKnown.keys.first);
    }
  }

  Map<String, Object?> _allPass() => {for (final id in _passKnown.keys) id: _passTag};

  void _savePass() {
    _passSaver?.cancel();
    _passSaver = null;
    unawaited(_passLog?.flush(standing: _passKnown.length, all: _allPass));
  }

  /// This hub runs inside someone's app (the app's lib/relay_host), not on a server: its hello says so (`"hosted":
  /// true`), so whoever joins is told that the person running it sees which installs talk and when (never what is
  /// said), as any relay's keeper does, and that it is up only while their app is. False, nothing is said.
  final bool hosted;

  /// Whether a connection from this machine or its private network that says, in `X-Forwarded-For`, whom it came from
  /// through a proxy is believed ([clientOf]): true, as before, for a relay behind its own web server (Caddy in front,
  /// as gogho.st is); false for one with nothing in front of it, as a relay hosted from the app is, where anyone on its
  /// network could say anything there and be counted as a new place each time.
  final bool trustsProxy;

  /// When this hub started, by its own clock. Said with each sign-in (`"since"`, beside its time now, `"now"`): what it
  /// kept for someone lives in memory and goes with a restart, so an app that knows when the relay started knows a
  /// packet it was told was kept before then is gone with it, and is no fault of the relay's (the app's
  /// docs/OPEN_NETWORK.md, section 3). An app from before passes over both. Where what is held is kept on disk
  /// ([keepHeld]) and the hub before this one stopped cleanly with nothing held in memory alone, it is when that one
  /// started: nothing kept since then went with the restart.
  DateTime get started => _started;
  DateTime _started;

  /// Whether what is held for people away, and what rooms keep, is kept on disk too (held_store.dart, under
  /// [dataDir]/held), so a restart loses at most its last moments (GMFB-24). Off unless its keeper switches it on
  /// (`GHOST_HUB_KEEP_HELD=1`): it puts sealed packets, and who each is for and from, on the server's disk for up to
  /// [holdFor]. Off, or with no [dataDir], nothing is written and everything is as it was.
  final bool keepHeld;
  late final HeldStore? _store = keepHeld && dataDir != null ? HeldStore(Directory('${dataDir!.path}/held')) : null;

  /// The store, for a test; null where [keepHeld] is off.
  HeldStore? get heldStore => _store;

  /// The link helpers this relay's people use for direct links between their devices (the app's
  /// docs/OPEN_NETWORK.md, section 2): servers that help two devices find each other and carry their sealed traffic
  /// when no straight path can be made. Said to each app as it signs in (`"helpers"` beside `"ok"`), as the call
  /// relay is handed out with a room; from `GHOST_LINK_HELPERS`. With none nothing is said, and an app from before
  /// passes it over either way. Set again (a relay hosted from the app, as its device's Direct comes to know helpers),
  /// those signing in from then on are told the new ones.
  List<String> get helpers => _helpers;
  set helpers(Iterable<String> said) => _helpers = linkHelpers(said);
  List<String> _helpers;

  /// The most link helpers named, and the longest address one may have.
  static const maxHelpers = 4;
  static const maxHelper = 200;

  /// [said] as link helpers are named: https addresses of at most [maxHelper] characters, the first [maxHelpers].
  static List<String> linkHelpers(Iterable<String> said) =>
      List.unmodifiable(said.map((h) => h.trim()).where((h) => h.length > 'https://'.length && h.length <= maxHelper && h.startsWith('https://')).take(maxHelpers));

  final bool verbose;

  /// The media relay calls fall back on (turn.dart): a username and password for it go with every room joined.
  final TurnConfig turn;
  final DateTime Function() _now;
  final Random _random;

  /// The handles people linked (handles.dart): what a connection says that starts `{"dir": …}` is its to answer.
  /// None where null, and such a message is then answered that there is none.
  final Handles? handles;

  /// Waking a closed iPhone when something is held for it (pushes.dart); none where null.
  final Pushes? pushes;

  /// Invites waiting for someone not on the app yet, by a hash of their number (invites.dart): the `{"dir": …}`
  /// messages it names ([Invites.dirs]) are its to answer, not [handles]'s. None where null, and they are then
  /// answered that there are none.
  final Invites? invites;

  /// Circles' invite words (invite_words.dart): the `{"dir": …}` messages it names ([InviteWords.dirs]).
  final InviteWords? words;

  /// Uplink accounts (accounts.dart): the `{"dir": "acct-…"}` messages ([Accounts.dirs]) are its to answer. None where
  /// null, and they are then answered that there are none. An app from before accounts never says them.
  final Accounts? accounts;

  /// Relays that talk to each other (federation.dart): this relay's own key and name, the home records people gave,
  /// and, where its keeper switched it on, the links to other relays a packet for someone who lives elsewhere is passed
  /// over. None where null: the hub is then exactly the one it was before any of it.
  final Federation? federation;

  /// What is signed to connect: these words, then the hub's number (v1, what every app signed before 2026-11-23).
  static const greeting = 'ghost-hub v1 ';

  /// What is signed to connect where the hub takes it (v2, found in the review of relays that talk, 2026-11-23): these
  /// words, the host the app dialled ([hostBytes]: its length, then it), then the hub's number. A v1 signature says
  /// nothing of where it was made, so a relay an app was pointed at, or asked a name of, could hand it the number of
  /// the app's own relay and sign in there as the app with the answer. A v2 signature is good only at a relay that is
  /// reached by that host ([names]); and a relay that has seen a key sign in with v2 takes no v1 from it again
  /// ([_signsV2]), so a v1 signature that key gives anywhere else is worth nothing here.
  static const greetingV2 = 'ghost-hub v2 ';

  /// What an app signs with v2 to the hub it reached at [host] (lower case, with its port where it is not the scheme's
  /// own), for the hub's number [nonce].
  static List<int> signedV2(String host, List<int> nonce) {
    final bytes = utf8.encode(host);
    return [...utf8.encode(greetingV2), bytes.length.clamp(0, 255), ...bytes.take(255), ...nonce];
  }

  /// The hosts this hub is reached at (`GHOST_HUB_NAMES`), as a v2 sign-in names them: lower case, with a port only
  /// where it is not 443 or 80. With none the hub takes v1 alone, as it always did, and says nothing of v2.
  final Set<String> names;

  /// [said] as hosts are named.
  static Set<String> hubNames(Iterable<String> said) => {
        for (final n in said.map((n) => n.trim().toLowerCase()).where((n) => n.isNotEmpty && n.length <= 200 && !n.contains('/') && !n.contains(' ')))
          n.endsWith(':443') || n.endsWith(':80') ? n.substring(0, n.lastIndexOf(':')) : n,
      };

  /// Where the names of the keys that have signed in with v2 are kept across restarts (`hub-v2.json`); none in memory.
  final Directory? dataDir;

  /// The keys that have signed in here with v2, the latest last: from any of them a v1 signature is refused. They are
  /// kept in two lots, those that held a username here when last seen ([_v2Named]) and the rest ([_v2Nameless]), at most
  /// [maxSignsV2] together. Past that, the one seen longest ago among those holding no name goes first (one found to hold
  /// a name by then moves to the other lot instead); one holding a name goes only when none without is left. So a stream
  /// of new keys, which hold no names, pushes out its own kind first (found in the second look at v2, 2026-11-23: with
  /// one lot, enough new keys would push out an account that had gone quiet here, and v1 would be taken from it again).
  final LinkedHashMap<String, bool> _v2Named = LinkedHashMap(), _v2Nameless = LinkedHashMap();
  final int maxSignsV2;

  /// How many keys new to those kept one place may add in an hour (a place: one IPv4 address, or one IPv6 address's
  /// first 48 bits: [placeOf]), and all places together. A sign-in past them is taken all the same, its key kept the
  /// next time it signs in with room; so pushing others out takes a great many places, and a long time, not one.
  final int newV2AnHour, newV2AnHourAll;

  /// The keys new to those kept that each place has added this hour, and all places together: when the hour began (ms)
  /// and how many. [_v2Places] places are remembered, the one counted longest ago let go first.
  final LinkedHashMap<String, ({int from, int n})> _v2From = LinkedHashMap();
  ({int from, int n}) _v2All = (from: 0, n: 0);
  static const _v2Places = 100000;

  /// How long a username must have been held for its key to be kept with those holding names ([_v2Named]): a name
  /// taken a moment ago costs nothing (found in the second review, 2026-11-23).
  static const v2NameAge = Duration(days: 2);

  /// The write that is due ([_saveV2]): two seconds after a key new to those kept signs in, once for all that follow.
  Timer? _v2Saver;

  /// Whether the key named [id] has signed in here with v2, for a test.
  bool signsV2(String id) => _v2Named.containsKey(id) || _v2Nameless.containsKey(id);

  /// How many keys are kept as having signed in with v2.
  int get keptV2 => _v2Named.length + _v2Nameless.length;

  /// Where the keys kept are written (`hub-v2.json`): a log of what changed, appended as it changes, written whole
  /// again only off the event loop (kept_log.dart); none in memory.
  late final KeptLog? _v2Log = dataDir == null ? null : KeptLog(File('${dataDir!.path}/hub-v2.json'));

  /// Whether [id] has held a username here for [v2NameAge] or longer.
  bool _holdsAName(String id) {
    final since = handles?.nameHeldSince(id);
    return since != null && _now().difference(since) >= v2NameAge;
  }

  /// The key [id] signed in with v2 from the place [from] ([placeOf]; '' for a connection made in this program).
  void _sawV2(String id, String from) {
    final had = _v2Named.remove(id) != null || _v2Nameless.remove(id) != null;
    if (!had && !_mayPinFrom(from)) return;
    (_holdsAName(id) ? _v2Named : _v2Nameless)[id] = true;
    while (keptV2 > maxSignsV2) {
      _evictV2();
    }
    if (had) return;
    _v2Log?.set(id, 1);
    if (_v2Log != null) _v2Saver ??= Timer(const Duration(seconds: 2), _saveV2);
  }

  /// Whether one more key new to those kept may be added from the place [from] this hour ([newV2AnHour],
  /// [newV2AnHourAll]); counted where it may.
  bool _mayPinFrom(String from) {
    final now = _now().millisecondsSinceEpoch, hour = const Duration(hours: 1).inMilliseconds;
    if (now - _v2All.from >= hour) _v2All = (from: now, n: 0);
    final was = _v2From.remove(from);
    final count = was == null || now - was.from >= hour ? (from: now, n: 0) : was;
    if (count.n >= newV2AnHour || _v2All.n >= newV2AnHourAll) {
      _v2From[from] = count;
      return false;
    }
    _v2From[from] = (from: count.from, n: count.n + 1);
    _v2All = (from: _v2All.from, n: _v2All.n + 1);
    while (_v2From.length > _v2Places) {
      _v2From.remove(_v2From.keys.first);
    }
    return true;
  }

  /// Lets one kept key go: the one seen longest ago that holds no name; only with none of those left, the one seen
  /// longest ago that does.
  void _evictV2() {
    while (_v2Nameless.isNotEmpty) {
      final oldest = _v2Nameless.keys.first;
      _v2Nameless.remove(oldest);
      // A name taken since it signed in: it is one of the named now, as recent as it was seen.
      if (!_holdsAName(oldest)) {
        _v2Log?.remove(oldest);
        return;
      }
      _v2Named[oldest] = true;
    }
    if (_v2Named.isNotEmpty) {
      final oldest = _v2Named.keys.first;
      _v2Named.remove(oldest);
      _v2Log?.remove(oldest);
    }
  }

  /// Reads the keys kept from `hub-v2.json` as the hub starts: the latest [maxSignsV2] of them.
  void _loadV2() {
    final log = _v2Log;
    if (log == null) return;
    // A file written whole, before (`{"v":1,"ids":[...]}`), is read and written as a log from the next save.
    final kept = log.load(whole: (all) => [for (final id in all['ids'] is List ? all['ids'] as List : const []) if (id is String) MapEntry(id, 1)]);
    final ids = kept.keys.where((id) => _hex(id, 32)).toList();
    // Sorted again by who holds a name now (handles are read first).
    for (final id in ids.length > maxSignsV2 ? ids.sublist(ids.length - maxSignsV2) : ids) {
      (_holdsAName(id) ? _v2Named : _v2Nameless)[id] = true;
    }
  }

  /// Every key kept, as the log writes them when it is written whole: those holding no name first.
  Map<String, Object?> _allV2() => {for (final id in [..._v2Nameless.keys, ..._v2Named.keys]) id: 1};

  /// Writes the keys kept that changed since: appended to the log, off the event loop (kept_log.dart).
  void _saveV2() {
    _v2Saver?.cancel();
    _v2Saver = null;
    unawaited(_v2Log?.flush(standing: keptV2, all: _allV2));
  }

  /// Who a connection is from, for counting what one place does ([newV2AnHour]): where it came through a proxy on this
  /// machine or its private network (Caddy, in front), the last address that proxy put in `X-Forwarded-For` (the one
  /// it saw: anything before it is what the asker said); else the connection's own address, whatever its headers say.
  static String clientOf(InternetAddress? peer, String? forwardedFor) {
    if (peer == null) return '';
    if ((peer.isLoopback || _privateAddress(peer)) && forwardedFor != null) {
      final said = InternetAddress.tryParse(forwardedFor.split(',').last.trim());
      if (said != null) return said.address;
    }
    return peer.address;
  }

  /// Whether [a] is on a private network: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, or IPv6's fc00::/7.
  static bool _privateAddress(InternetAddress a) {
    final b = a.rawAddress;
    if (a.type == InternetAddressType.IPv4) return b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] < 32) || (b[0] == 192 && b[1] == 168);
    if (a.type == InternetAddressType.IPv6) return (b[0] & 0xfe) == 0xfc;
    return false;
  }

  /// The place [address] counts as: an IPv4 address itself (also written as IPv6), an IPv6 address by its first 48 bits,
  /// what one customer of a network is commonly given (whoever has one address there may have all of them).
  static String placeOf(String address) {
    final a = InternetAddress.tryParse(address);
    if (a == null || a.type != InternetAddressType.IPv6) return address;
    final b = a.rawAddress;
    if (b.sublist(0, 10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff) return '${b[12]}.${b[13]}.${b[14]}.${b[15]}';
    return '${[for (var i = 0; i < 6; i += 2) ((b[i] << 8) | b[i + 1]).toRadixString(16)].join(':')}::/48';
  }

  /// What every connection through the hub's door may hold together, waiting to go out or half come in (ws_door.dart,
  /// [WireBudget]): the whole process's unless given one.
  final WireBudget wire;

  /// What an app from before is told when its account signs in with v2 here.
  static const refusedOld = 'This account signs in a newer way now: update Uplink on this device.';

  /// How long the answer to an app from before refused again within the hour waits ([_holdRefusal]), and how many may
  /// wait at once (past that it is answered at once).
  final Duration oldAppHold;
  final int heldRefusalsMost;

  /// The refusals waiting to be said, and when each key's app from before was last refused (50,000 are remembered).
  final Set<Timer> _refusalsHeld = {};
  final LinkedHashMap<String, DateTime> _refusedOldAt = LinkedHashMap();

  /// Whether the refusal to [id]'s app from before is to wait: refused already within the hour, and room to wait.
  bool _holdRefusal(String id) {
    final now = _now();
    final last = _refusedOldAt.remove(id);
    _refusedOldAt[id] = now;
    while (_refusedOldAt.length > 50000) {
      _refusedOldAt.remove(_refusedOldAt.keys.first);
    }
    return last != null && now.difference(last) < const Duration(hours: 1) && _refusalsHeld.length < heldRefusalsMost;
  }

  /// How much is held for everyone together, in bytes, and how many may be connected: a server with a few hundred
  /// megabytes to itself, open to anyone who can make a key, is not to be filled by them.
  ///
  /// A held packet is counted as its bytes and [heldOverhead] more: what holding it costs beside its bytes. Counted
  /// by its bytes alone, one connection sending the smallest packets to made-up names filled several times
  /// [heldBytes] of memory before the count said full.
  final int heldBytes;
  final int maxConnections;
  int _held = 0;

  /// What holding one packet costs beside its bytes: its place in a mailbox, the byte array's and the record's own
  /// headers, when it came. Rounded up, so [heldBytes] is never less than the memory it stands for.
  static const heldOverhead = 256;

  static const maxPacket = 64 * 1024;

  /// The longest message the hub reads, in bytes: the longest an app says is a list of 5,000 keys watched or a kept
  /// blob of 256 KB, and this has room to spare. One longer ends the connection before a byte of it is held, and so
  /// does a first message (the hello) of more than 16 KB (ws_door.dart).
  static const maxMessage = 1 << 20;
  static const mailboxFrames = 200;
  static const mailboxBytes = 1 << 20;
  static const holdFor = Duration(days: 7);
  static const maxRoom = 64;
  static const maxRooms = 50000;
  static const maxWatched = 500;
  static const authWait = Duration(seconds: 10);

  /// How many names' last-seen times are kept; the oldest go first.
  static const maxSeen = 200000;

  /// A packet to one person, and one to a room: the first byte of a binary message.
  static const toPeer = 1;
  static const toRoom = 2;

  /// A packet to a room that is kept as well, for whoever joins it later (Matt, 2026-11-18: "I can't see their messages
  /// in spaces within a circle"): the hub kept nothing of a room, so what was written while a phone was closed came to
  /// it only if a member who had it was in the room when it came back. The app marks a space's words, deletions,
  /// roster and description so ([toRoomKept]); each joining device is handed what is kept, sealed as it came, which
  /// the hub cannot read. Handed on as [toRoom], so nothing on the app's side reads another kind.
  static const toRoomKept = 3;

  /// A reaction to a message in a room (Matt, 2026-11-20: "add reactions after done to spaces and circles"): kept as
  /// [toRoomKept] is, handed to everyone in the room, and passed on with this first byte so the apps take nothing but a
  /// reaction from it. At most [maxReaction] bytes. The one thing someone who may not post in a read-only room may send
  /// to everyone there: a reaction is no post, and a packet that small carries no message the apps would show.
  static const toRoomReaction = 4;
  static const maxReaction = 512;

  /// A packet a name sent to itself, handed to one of its own devices that asked for it (`stamp: true` in its hello)
  /// with the device that sent it, as that device said it in its hello: `[7][from, 16 bytes][n][device, n bytes][the
  /// packet]` (GMFB-53: a history goes only to the device that asked for it, which only the hub can vouch for). Every
  /// other connection, and every other packet, is handed [toPeer] as before, byte for byte.
  static const toPeerFromDevice = 7;

  /// [frame] (a [toPeer] frame) with the device that sent it put in ([toPeerFromDevice]).
  static Uint8List stamped(Uint8List frame, String device) {
    final d = utf8.encode(device);
    return Uint8List.fromList([toPeerFromDevice, ...frame.sublist(1, 17), d.length, ...d, ...frame.sublist(17)]);
  }

  /// The frame [to] is handed of [frame], a packet its name sent itself from [device]: stamped where it asked to be.
  static Uint8List _forDevice(_End to, Uint8List frame, String? device) => to.stamps && device != null && device.isNotEmpty ? stamped(frame, device) : frame;

  /// What a room keeps: its newest [roomKeepFrames], none older than [roomKeepFor], [roomKeepBytes] in all at most (256 MB
  /// unless the hub is given less: a relay hosted from the app keeps far less, in the app's memory).
  static const roomKeepFrames = 300;
  static const roomKeepFor = Duration(days: 7);
  final int roomKeepBytes;

  /// Kept packets by room, with the hash of the room's token, so only one who knows it is handed them.
  final Map<String, ({String hash, List<_Held> frames})> _kept = {};
  int _keptBytes = 0;

  /// How many packets [room] keeps, for a test.
  int keptIn(String room) => _kept[room]?.frames.length ?? 0;

  /// Adds [frame] to what the room kept under [name] keeps. A room whose token changed (another [hash]) starts again
  /// with nothing, so what was kept under the old token is never handed to holders of the new one. [loaded]: one read
  /// back from the store ([keepHeld]), kept again under the same limits and not written again.
  void _keep(String name, String hash, Uint8List frame, {_Held? loaded}) {
    var box = _kept[name];
    if (box == null || box.hash != hash) {
      if (box != null) {
        _keptBytes -= box.frames.fold<int>(0, (n, h) => n + h.frame.length);
        box.frames.forEach(_unstore);
      }
      box = _kept[name] = (hash: hash, frames: <_Held>[]);
    }
    final h = loaded ?? _Held(frame, _now());
    if (loaded == null) h.seq = _store?.addKept(name, hash, h.at, frame) ?? 0;
    box.frames.add(h);
    _keptBytes += frame.length;
    while (box.frames.length > roomKeepFrames) {
      final gone = box.frames.removeAt(0);
      _keptBytes -= gone.frame.length;
      _unstore(gone);
    }
    // Over the whole store's cap: the oldest of the busiest room goes first.
    while (_keptBytes > roomKeepBytes && _kept.isNotEmpty) {
      final biggest = _kept.entries.reduce((a, b) => a.value.frames.length >= b.value.frames.length ? a : b);
      if (biggest.value.frames.isEmpty) {
        _kept.remove(biggest.key);
        continue;
      }
      final gone = biggest.value.frames.removeAt(0);
      _keptBytes -= gone.frame.length;
      _unstore(gone);
    }
  }

  /// [h] is no longer held: off the disk too, where it was kept there.
  void _unstore(_Held h) {
    if (h.seq != 0) _store?.drop(h.seq);
    h.seq = 0;
  }

  /// Reads back what the store kept ([keepHeld]), under the limits as they are now: anything past [holdFor] (or a
  /// room's [roomKeepFor]), or past [mailboxFrames], [mailboxBytes] or [heldBytes], is dropped, from the disk too.
  void _loadHeld() {
    final store = _store;
    if (store == null) return;
    final items = store.load();
    final since = store.cleanSince;
    if (since != null && since <= _started.millisecondsSinceEpoch) _started = DateTime.fromMillisecondsSinceEpoch(since, isUtc: _started.isUtc);
    final cutoff = _now().subtract(holdFor), keptCutoff = _now().subtract(roomKeepFor);
    final sizes = <String, int>{};
    for (final s in items) {
      final h = _Held(s.frame, s.at, byDevice: s.byDevice)..seq = s.seq;
      if (!s.isMail) {
        s.at.isAfter(keptCutoff) && _hex(s.hash, 64) ? _keep(s.room!, s.hash!, s.frame, loaded: h) : _unstore(h);
        continue;
      }
      final to = s.to!, size = sizes[to] ?? 0, box = _mail[to];
      if (!s.at.isAfter(cutoff) || (box?.length ?? 0) >= mailboxFrames || size + s.frame.length > mailboxBytes || _held + h.cost > heldBytes) {
        _unstore(h);
        continue;
      }
      (_mail[to] ??= []).add(h);
      sizes[to] = size + s.frame.length;
      _held += h.cost;
    }
  }

  /// Who is here, by name: every device signed in under it (Matt, 2026-11-18: "I want desktop to be able to run
  /// standalone for internal friends and circles ... even if the desktop is linked": a phone and its computer, one
  /// identity, both here). Each says which device it is (`device` in its hello); a connection from the same device
  /// takes its place, as one name's connection always did. An app from before says none, and takes the place of any
  /// other that said none.
  final Map<String, List<_End>> _here = {};

  /// The most devices here under one name at once; one more takes the place of the longest here.
  static const maxDevices = 8;

  bool _isHere(String id) => _here[id]?.isNotEmpty ?? false;

  /// Whether [id] has signed in here: here now, seen since the hub started, holding a username, or having given its
  /// own home record here. What another relay passes on is kept only for such a name (federation.dart).
  bool _knows(String id) => _isHere(id) || _seen.containsKey(id) || (handles?.holdsAName(id) ?? false) || (federation?.homes.isOwn(id) ?? false);

  /// The numbers this hub made up for the hellos it is still waiting on, in hex: how this relay knows itself when it
  /// dials an address and finds its own hub there (federation.dart).
  final Set<String> _nonces = {};

  /// [id] chose how they are shown (GMFB-34): told to whoever watches them, once a change.
  void _setMode(String id, String said) {
    final mode = said == 'busy' || said == 'invisible' ? said : '';
    final was = _mode[id] ?? '';
    if (mode == was || !_isHere(id)) return;
    if (mode.isEmpty) {
      _mode.remove(id);
    } else {
      _mode[id] = mode;
    }
    final watchers = [...?_watching[id]];
    final at = _now().millisecondsSinceEpoch;
    if (mode == 'invisible') {
      // Gone, to watchers, as of now; last seen not moved on while hidden.
      _keepSeen(id, at);
      for (final w in watchers) {
        _tell(w.ws, {'went': id, 'at': at});
      }
      return;
    }
    for (final w in watchers) {
      if (was == 'invisible') {
        _tell(w.ws, {'came': id});
        if (_awaySince.containsKey(id)) _tell(w.ws, {'away': id, 'is': true, 'at': _awaySince[id]});
      }
      if ((was == 'busy') != (mode == 'busy')) _tell(w.ws, {'busy': id, 'is': mode == 'busy'});
    }
  }

  /// Whether every device here under [id] has the app put away: away, under a name with several devices here, is
  /// every one of them away, and only then is the name told as away.
  bool _allAway(String id) => (_here[id] ?? const <_End>[]).every((e) => e.away);

  /// [_mail]: packets held for each name that is away. [_rooms]: every room someone is in, by its key ([_keyOf]).
  /// [_watching]: for each watched name, the connections to tell when it comes, goes or is put away.
  final Map<String, List<_Held>> _mail = {};
  final Map<String, _Room> _rooms = {};
  final Map<String, Set<_End>> _watching = {};

  /// When each name that has gone was last using the app (ms since 1970), oldest first.
  final Map<String, int> _seen = {};

  /// Those here with the app put away, and since when.
  final Map<String, int> _awaySince = {};

  /// How each person here chose to be shown, where not plainly: 'busy' or 'invisible' (GMFB-34).
  final Map<String, String> _mode = {};

  /// Here and not hiding: what watchers are told.
  bool _shown(String id) => _isHere(id) && _mode[id] != 'invisible';

  void _keepSeen(String id, int at) {
    _seen.remove(id);
    _seen[id] = at;
    while (_seen.length > maxSeen) {
      _seen.remove(_seen.keys.first);
    }
  }

  /// When [id] was last seen, for a test.
  int? seenOf(String id) => _seen[id];

  /// Who is looking at a room without being in it (a voice channel's list: who is connected), by room, with the hash
  /// of the token each looked with. Told who is in it now and whenever that changes; a wrong token is told nothing.
  final Map<String, Map<_End, String>> _lookers = {};
  // The most rooms one connection may look at.
  static const maxLooks = 200;
  Timer? _sweeper;

  // Open WebSockets, signed in or not yet: what maxConnections is held against. `connected` counts the signed in.
  int _open = 0;
  int get connected => _here.values.fold(0, (n, l) => n + l.length);

  /// How much is held for people who are away, in bytes.
  int get holding => _held;
  int get rooms => _rooms.length;
  // How many packets are held for [id].
  int heldFor(String id) => _mail[id]?.length ?? 0;

  /// Loads what each part keeps on disk, and every ten minutes drops what has grown old here and in each of them.
  void start() {
    handles?.load();
    _loadV2();
    _loadPass();
    _loadHeld();
    invites?.load();
    words?.load();
    accounts?.load();
    federation?.start();
    _sweeper ??= Timer.periodic(const Duration(minutes: 10), (_) {
      sweep();
      handles?.sweep();
      accounts?.sweep();
      accounts?.save();
      words?.sweep();
      final i = invites;
      if (i != null) unawaited(i.sweep());
    });
  }

  /// Writes what each part keeps and closes every connection. Held and kept packets go with it, unless [keepHeld]
  /// keeps them on disk, where the next start reads them back.
  void stop() {
    // Read before federation stops: what waits for another relay lives in memory alone.
    final nothingInMemoryAlone = (federation?.waiting ?? 0) == 0;
    _sweeper?.cancel();
    _sweeper = null;
    for (final t in _refusalsHeld) {
      t.cancel();
    }
    _refusalsHeld.clear();
    _v2Saver?.cancel();
    _v2Saver = null;
    _v2Log?.flushNow(standing: keptV2, all: _allV2);
    _passSaver?.cancel();
    _passSaver = null;
    _passLog?.flushNow(standing: _passKnown.length, all: _allPass);
    handles?.save();
    invites?.save();
    words?.save();
    accounts?.save();
    federation?.stop();
    for (final end in _here.values.expand((l) => l).toList()) {
      end.ws.close(WebSocketStatus.goingAway);
    }
    // After the connections: what was being handed over and not written is held again, and stays on the disk. The
    // start is carried over only where nothing held lived in memory alone (another relay's queue does).
    _store?.close(since: nothingInMemoryAlone ? _started.millisecondsSinceEpoch : null);
  }

  static final _hexOnly = RegExp(r'^[0-9a-f]+$');
  static bool _hex(Object? text, int length) => text is String && text.length == length && _hexOnly.hasMatch(text);
  static List<int> _unhex(String text) => [for (var i = 0; i + 1 < text.length; i += 2) int.parse(text.substring(i, i + 2), radix: 16)];

  /// Whether [a] and [b] are the same bytes, looked at whole whatever they are: how long it takes says nothing of where
  /// they differ.
  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var d = 0;
    for (var i = 0; i < a.length; i++) {
      d |= a[i] ^ b[i];
    }
    return d == 0;
  }

  /// The name a public key is known by here.
  static String nameOf(List<int> publicKey) => hexOf(sha256(publicKey).sublist(0, 16));

  /// What a read-only room's name is made from: these words, then 16 bytes only its members know (from the space's
  /// seed), then the circle owner's public key (33 bytes).
  static const anchorWords = 'ghost-ro|';

  /// The name of the read-only room made from [base] for the circle owner [owner].
  static String anchoredName(List<int> base, List<int> owner) => hexOf(sha256([...utf8.encode(anchorWords), ...base, ...owner]).sublist(0, 16));

  /// What the circle's owner signs for generation [gv] of its admin list (CircleManifest.grantsMessage in the app).
  static List<int> grantsMessage(String owner, int gv, Map<String, String> grants) =>
      utf8.encode('ghost-circle grants|$owner|$gv|${jsonEncode(Map.fromEntries(grants.entries.toList()..sort((a, b) => a.key.compareTo(b.key))))}');

  /// What the owner signs to make [id] an admin (CircleManifest.grantMessage in the app).
  static List<int> grantMessage(String owner, String id) => utf8.encode('ghost-circle admin|$owner|$id');

  /// The most admins a read-only room's list is read for.
  static const maxGrants = 200;

  /// The key a room is kept under: a read-only room's apart from an ordinary one of the same name.
  static String _keyOf(String name, bool anchored) => anchored ? 'ro:$name' : name;
  static String _nameOf(String key) => key.startsWith('ro:') ? key.substring(3) : key;

  /// The room [e] is in by [name]: its read-only one where it joined that.
  String _keyIn(_End e, String name) => e.rooms.contains('ro:$name') ? 'ro:$name' : name;

  /// Who may post in a read-only room, for a test.
  Set<String>? writersIn(String name) => _rooms['ro:$name']?.writers;

  /// Takes the admin list [ro] carries for [room]: a newer generation signed by the owner replaces what is kept; a
  /// circle from before generations (0) adds each grant that checks out. Anything that doesn't check out is passed over.
  void _takeGrants(_Room room, Map ro) {
    final owner = room.owner;
    if (owner == null) return;
    final gv = ro['gv'] is int ? ro['gv'] as int : 0;
    final raw = ro['g'] is Map ? ro['g'] as Map : const {};
    final grants = <String, String>{
      for (final e in raw.entries.take(maxGrants))
        if (_hex(e.key, 32) && _hex(e.value, 128)) e.key as String: e.value as String,
    };
    bool granted(String id) {
      try {
        return P256.verify(_unhex(owner), grantMessage(owner, id), _unhex(grants[id]!));
      } catch (_) {
        return false;
      }
    }

    if (gv > 0) {
      if (gv <= room.gv || !_hex(ro['gs'], 128)) return;
      if (raw.length > maxGrants || !P256.verify(_unhex(owner), grantsMessage(owner, gv, grants), _unhex(ro['gs'] as String))) return;
      room.gv = gv;
      room.writers
        ..clear()
        ..add(room.ownerId)
        ..addAll(grants.keys.where(granted));
    } else if (room.gv <= 0) {
      room.gv = 0;
      room.writers.addAll(grants.keys.where(granted));
    }
  }

  void _say(String what) {
    // Never an address, never a whole name.
    if (verbose) stdout.writeln('${_now().toIso8601String()} hub $what');
  }

  /// Says [what] to [ws] as JSON, where there is one and it is still open.
  void _tell(HubSocket? ws, Map<String, Object?> what) {
    if (ws == null || !ws.isOpen) return;
    try {
      ws.add(jsonEncode(what));
    } catch (_) {}
  }

  /// Takes a connection that asked for the hub (the relay hands over any address ending in `/hub`).
  ///
  /// The hub says `{hello: <its number, hex>}`; the app answers `{id, key, sig, device?, peek?}` and is told
  /// `{ok, held}` and handed what was held for it. After that a binary message is a packet ([_packet]) and a text one
  /// is JSON, known by its key: `ping`, `push` (pushes.dart), `dir` (accounts, invite words, invites, handles, in that
  /// order), `watch`, `mode`, `away`, `join`, `anchor`, `leave`, `look`, `unlook`. Close codes: 4400 bad hello, 4401 no hello
  /// in time, 4409 replaced by a newer connection of the same device.
  Future<void> accept(HttpRequest request) async {
    if (_open >= maxConnections) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
      return;
    }
    // Where it is from, read before the upgrade: a request with two X-Forwarded-For lines, read as one, would throw
    // after the 101 and leave a connection nothing is said on (found in the second review, 2026-11-23). The last line
    // is the proxy's own.
    final from = placeOf(clientOf(request.connectionInfo?.remoteAddress, trustsProxy ? request.headers['x-forwarded-for']?.last : null));
    final WebSocket ws;
    try {
      // No compression: a message is held whole before its length is looked at, and a deflated one of a few hundred
      // kilobytes opens out to hundreds of megabytes (found in review, 2026-11-22). Sealed packets don't shrink anyway.
      // And a ceiling on a message's length in front of the parser, for one sent as it is (ws_door.dart).
      final up = await upgradeGuarded(request, most: maxMessage, budget: wire);
      if (up == null) return;
      ws = up;
    } catch (_) {
      return;
    }
    ws.pingInterval = const Duration(seconds: 30);
    attach(_WebSocketHubSocket(ws), from: from);
  }

  /// Takes a connection whatever carries it: the WebSocket [accept] upgraded, or any other [HubSocket] (one made in
  /// this very program, another relay's, a peer-to-peer stream). It is said hello to and heard from then on, as a
  /// WebSocket always was. [maxConnections] counts these too: one more than that is closed at once (4503, "full").
  /// [own]: the keeper's own app, in memory in the same program (the app's lib/relay_host), which is never asked for the
  /// pass phrase, so nothing a stranger does can refuse it.
  ///
  /// [reachedAs]: how the app at the far end names this relay's place (the node id its Direct connection came in at; the
  /// relay's name in memory): the hello carries this relay's signature over it and the connection's number
  /// (`"relaySig"`, [Federation.signReached]), where it has a key.
  void attach(HubSocket socket, {String from = '', bool own = false, String? reachedAs}) {
    if (_open >= maxConnections) {
      socket.close(4503, 'full');
      return;
    }
    _open++;
    var counted = true;
    // The hub's number: made fresh for each connection, so a signature heard once signs nobody in again.
    final nonce = [for (var i = 0; i < 32; i++) _random.nextInt(256)];
    final number = hexOf(nonce);
    _nonces.add(number);
    _End? end;
    final waiting = Timer(authWait, () {
      if (end == null) socket.close(4401, 'no hello');
    });
    // `peek`: this hub knows a look (below), so a closed app's check can sign in without being handed anything; a
    // hub from before would hand it all over, and the check does not sign in to one that does not say so.
    // `react`: this hub takes reactions ([toRoomReaction]); an app sends them as kept packets to one that doesn't say so.
    // `relay`: this relay's own name and key, where it has them (federation.dart); an app from before passes over it.
    // `v2`: this hub takes a sign-in bound to the host it is reached at ([greetingV2]); said only where its names are
    // known, and an app from before passes over it.
    // `hosted` and `pass`: this hub runs in someone's app ([hosted]), and asks for a pass phrase ([asksPass]); each said
    // only where it is so, and an app from before passes over both.
    final reachedSig = reachedAs == null ? null : federation?.signReached(nonce, reachedAs);
    _tell(socket, {'hello': hexOf(nonce), 'peek': true, 'react': true, 'relay': ?federation?.card, if (reachedSig != null) 'relaySig': base64Encode(reachedSig), if (names.isNotEmpty) 'v2': true, if (hosted) 'hosted': true, if (_pass != null) 'pass': true, if (_pass != null) 'salt': passSalt});

    // Another relay's link, once its hello has come in place of an app's: what it says from then on is federation's.
    FedEnd? link;

    // This connection has ended: out of its rooms, looks and watches, and, where it was the name's last device here,
    // those watching the name are told it went and when it was last using the app.
    void leave() {
      waiting.cancel();
      _nonces.remove(number);
      if (counted) {
        counted = false;
        _open--;
      }
      link?.gone();
      link = null;
      final e = end;
      if (e == null) return;
      end = null;
      for (final room in e.rooms.toList()) {
        _leave(e, room);
      }
      for (final room in e.looks.toList()) {
        _unlook(e, room);
      }
      for (final id in e.watches.toList()) {
        final set = _watching[id];
        set?.remove(e);
        if (set != null && set.isEmpty) _watching.remove(id);
      }
      handles?.went(e.id, e.tell);
      final list = _here[e.id];
      if (list == null || !list.remove(e)) return; // replaced by a newer connection from the same device
      if (list.isNotEmpty) {
        // Another device of theirs is still here: not gone, though maybe now away (every one left is).
        final away = _allAway(e.id);
        if (away != _awaySince.containsKey(e.id)) {
          final at = _now().millisecondsSinceEpoch;
          if (away) {
            _awaySince[e.id] = at;
          } else {
            _awaySince.remove(e.id);
          }
          for (final w in [...?_watching[e.id]]) {
            _tell(w.ws, {'away': e.id, 'is': away, 'at': at});
          }
        }
        return;
      }
      _here.remove(e.id);
      // Invisible, they were gone to watchers already, and their last seen was not moved on.
      final hidden = _mode.remove(e.id) == 'invisible';
      // Last seen: when they put the app away, where they had, else now.
      final at = _awaySince.remove(e.id) ?? _now().millisecondsSinceEpoch;
      if (hidden) return;
      _keepSeen(e.id, at);
      for (final w in [...?_watching[e.id]]) {
        _tell(w.ws, {'went': e.id, 'at': at});
      }
      _say('${e.id.substring(0, 6)} left');
    }

    socket.incoming.listen((data) {
      final other = link;
      if (other != null) return other.heard(data);
      final e = end;
      if (e == null) {
        // The first thing said: who this is, and the hub's number signed with their key.
        Map? hello;
        try {
          hello = data is String ? jsonDecode(data) as Map : null;
        } catch (_) {}
        // Not an app but another relay (`"fed": 1`): federation's to answer, where this hub has it on. One with none, or
        // with it off, answers as it always answered a hello it could not read.
        final fed = federation;
        if (fed != null && fed.on && hello != null && hello['fed'] == 1) {
          waiting.cancel();
          _nonces.remove(number);
          link = fed.incoming(socket, hello, nonce);
          return;
        }
        List<int>? key, sig;
        try {
          key = base64Decode(hello?['key'] as String);
          sig = base64Decode(hello?['sig'] as String);
        } catch (_) {}
        final id = hello?['id'];
        void bad([String why = 'bad hello']) {
          _tell(socket, {'ok': false, 'err': why});
          socket.close(4400, 'bad hello');
        }

        if (key == null || sig == null || !_hex(id, 32) || nameOf(key) != id) return bad();
        // A hub that asks for a pass phrase takes nothing without it, a look neither: looked at before the signature,
        // being far cheaper. None given is said so, and counts for nothing (an app not told the phrase yet tries again);
        // a wrong one costs its place, and strangers together ([passGuessesFree]). The keeper's own app isn't asked.
        var passRight = false;
        if (_pass != null && !own) {
          final passKey = _passKey!;
          void noPass(String kind, [int? waitMs]) {
            _tell(socket, {'ok': false, 'err': kind == 'busy' ? 'Too many wrong pass phrases lately. Try again in a while.' : kind == 'wrong' ? 'That pass phrase isn\'t this relay\'s.' : 'This relay asks for a pass phrase.', 'pass': kind, if (waitMs != null) 'wait': (waitMs + 999) ~/ 1000});
            socket.close(4401, 'pass');
          }

          bool signed() {
            if (hello?['v'] == 2) {
              final host = hello?['host'];
              return host is String && names.contains(host.toLowerCase()) && P256.verify(key!, signedV2(host.toLowerCase(), nonce), sig!);
            }
            return P256.verify(key!, [...utf8.encode(greeting), ...nonce], sig!);
          }

          final said = hello?['pass'];
          if (said == null) return noPass('needed');
          final wait = _passWait(from, id as String, signed);
          if (wait != null) return noPass('busy', wait);
          if (!_hex(said, 64) || !_same(_unhex(said as String), passProof(passKey, nonce, id))) {
            _passWasWrong(from);
            return noPass('wrong');
          }
          passRight = true;
        }
        if (hello?['v'] == 2) {
          // Bound to the host it was signed for, which must be one this hub is reached at.
          final host = hello?['host'];
          if (host is! String || !names.contains(host.toLowerCase())) return bad('This relay isn\'t reached as ${host is String && host.length <= 200 ? host : 'that'}.');
          if (!P256.verify(key, signedV2(host.toLowerCase(), nonce), sig)) return bad();
          _sawV2(id, from);
        } else {
          // A key that has signed in here with v2 signs every sign-in here so, while this hub is reached by its names: a
          // v1 signature of its is one made somewhere else, for anyone to pass on. With the names taken away the hub
          // offers no v2, so even the newest app signs v1 then, and is taken (found in the second review, 2026-11-23:
          // it was refused). Looked at before the signature is checked: an app from before retries every half minute
          // after a refusal, and checking costs milliseconds. Refused again within the hour, it is answered late, the
          // connection open meanwhile, so it comes back a few times an hour instead of a hundred.
          if (names.isNotEmpty && signsV2(id)) {
            if (!_holdRefusal(id)) return bad(refusedOld);
            waiting.cancel();
            late final Timer later;
            later = Timer(oldAppHold, () {
              _refusalsHeld.remove(later);
              bad(refusedOld);
            });
            _refusalsHeld.add(later);
            return;
          }
          if (!P256.verify(key, [...utf8.encode(greeting), ...nonce], sig)) return bad();
        }
        waiting.cancel();
        _nonces.remove(number);
        if (passRight) _passWasRight(id as String);
        // A look, not a coming (Matt, 2026-11-16: "Yes, wake-ups"): a closed app's check, every so often, of whether
        // anything is held for it. Told how many, and nothing is handed over or taken, nor the app's own connection
        // replaced: the app gets them when it opens.
        if (hello?['peek'] == true) {
          final cutoff = _now().subtract(holdFor);
          final count = (_mail[id] ?? const <_Held>[]).where((h) => h.at.isAfter(cutoff)).length;
          _tell(socket, {'ok': true, 'held': count, 'peek': true, 'here': _isHere(id as String)});
          socket.close(1000, 'looked');
          return;
        }
        final device = hello?['device'] is String && (hello!['device'] as String).length <= 64 ? hello['device'] as String : '';
        final made = _End(id as String, socket, (what) => _tell(socket, what), device: device, place: from, stamps: hello?['stamp'] == true);
        final list = _here[made.id] ??= [];
        final first = list.isEmpty;
        // The same device again (a reconnect) takes its own place; the longest here goes where there are too many.
        for (final old in [...list.where((o) => o.device == device), if (list.length >= maxDevices) list.first]) {
          list.remove(old);
          old.ws.close(4409, 'replaced');
        }
        list.add(made);
        // Another device coming while the others were put away: back, to whoever watches.
        if (_awaySince.remove(made.id) != null && !first) {
          for (final w in [...?_watching[made.id]]) {
            _tell(w.ws, {'away': made.id, 'is': false, 'at': _now().millisecondsSinceEpoch});
          }
        }
        end = made;
        handles?.came(made.id, made.tell, key: key);
        final all = _mail.remove(made.id) ?? const <_Held>[];
        // What this very device sent to its own name stays kept for the others (a device from before devices, with no
        // name, is handed everything, as before).
        final back = [for (final h in all) if (h.byDevice != null && h.byDevice == made.device) h];
        final held = [for (final h in all) if (!back.contains(h)) h];
        if (back.isNotEmpty) _mail[made.id] = back;
        _held -= held.fold<int>(0, (n, h) => n + h.cost);
        final cutoff = _now().subtract(holdFor);
        final fresh = held.where((h) => h.at.isAfter(cutoff)).toList();
        for (final h in held) {
          if (!h.at.isAfter(cutoff)) _unstore(h);
        }
        _tell(socket, {'ok': true, 'held': fresh.length, 'now': _now().millisecondsSinceEpoch, 'since': started.millisecondsSinceEpoch, if (helpers.isNotEmpty) 'helpers': helpers});
        // Handed over as fast as the device takes them; what isn't written by the time it goes is kept again.
        // Each one written is off the disk too; one not written stays there, held again.
        var given = 0;
        _handOver(socket, [for (final h in fresh) _forDevice(made, h.frame, h.byDevice)], notGiven: (left) => _holdAgain(made.id, fresh.sublist(fresh.length - left)), gone: () => _unstore(fresh[given++]));
        // A mode said with the hello holds from the first moment: someone invisible never shows as come.
        final asked = hello?['mode'];
        if (first && asked is String && (asked == 'busy' || asked == 'invisible')) _mode[made.id] = asked;
        if (first && _shown(made.id)) {
          for (final w in [...?_watching[made.id]]) {
            _tell(w.ws, {'came': made.id});
            if (_mode[made.id] == 'busy') _tell(w.ws, {'busy': made.id, 'is': true});
          }
        }
        _say('${made.id.substring(0, 6)} came${fresh.isEmpty ? '' : ', ${fresh.length} held'}');
        return;
      }
      if (data is List<int>) {
        _packet(e, data);
        return;
      }
      Map? said;
      try {
        said = jsonDecode(data as String) as Map;
      } catch (_) {}
      if (said == null) return;
      if (said.containsKey('ping')) {
        _tell(socket, {'pong': said['ping']});
      } else if (said.containsKey('push')) {
        // This install's token for push notifications (an iPhone), or null to forget it.
        pushes?.said(e.id, said['push'], device: e.device);
        _tell(socket, {'push': pushes != null});
      } else if (federation != null && federation!.on && said['dir'] is String && Federation.takes(said)) {
        // A home record given or asked for, or a username on another relay (federation.dart). With federation off they
        // are answered as a relay from before answered them.
        federation!.said(e.id, said, e.tell, place: e.place);
      } else if (said['dir'] is String && Accounts.dirs.contains(said['dir'])) {
        // A `dir` message goes to the part that names it, tried in this order; any other is the handles' to answer.
        final a = accounts;
        if (a == null) {
          _tell(socket, {'dir': 'err', 'about': said['dir'], 'err': 'This server keeps no accounts.'});
        } else {
          a.said(e.id, said, (m) => _tell(socket, m));
        }
      } else if (said['dir'] is String && InviteWords.dirs.contains(said['dir'])) {
        final w = words;
        if (w == null) {
          _tell(socket, {'dir': 'err', 'about': said['dir'], 'err': 'This server keeps no invite words.'});
        } else {
          w.said(e.id, said, (m) => _tell(socket, m));
        }
      } else if (said['dir'] is String && Invites.dirs.contains(said['dir'])) {
        final i = invites;
        if (i == null) {
          _tell(socket, {'dir': 'err', 'about': said['dir'], 'err': 'This server keeps no invites.'});
        } else {
          i.said(e.id, said, (m) => _tell(socket, m));
        }
      } else if (said['dir'] is String) {
        final h = handles;
        if (h == null) {
          _tell(socket, {'dir': 'err', 'about': said['dir'], 'err': 'This server keeps no handles.'});
        } else {
          // The asking connection's own tell, as came and went are given: the answer goes to the device that asked.
          // Where relays talk, who has a username is told with their home record, as a linked relay is told it: what
          // someone on another relay needs to be friends with them (federation.dart).
          final fed = federation;
          h.said(e.id, said, fed != null && fed.on && said['dir'] == 'whois' ? (m) => e.tell(fed.withHome(m)) : e.tell);
        }
      } else if (said['watch'] is List) {
        // Names to be told about from now on, and how each stands now: here, here but away, or when last seen.
        final ids = (said['watch'] as List).where((i) => _hex(i, 32)).cast<String>().take(maxWatched).toList();
        for (final id in ids) {
          if (e.watches.length >= maxWatched && !e.watches.contains(id)) break;
          e.watches.add(id);
          (_watching[id] ??= {}).add(e);
        }
        _tell(socket, {
          'here': [for (final id in ids) if (_shown(id)) id],
          'away': [for (final id in ids) if (_shown(id) && _awaySince.containsKey(id)) id],
          'busy': [for (final id in ids) if (_shown(id) && _mode[id] == 'busy') id],
          'seen': {for (final id in ids) if (!_shown(id) && _seen.containsKey(id)) id: _seen[id]},
        });
      } else if (said['mode'] is String) {
        // `{"mode": "online" | "busy" | "invisible"}`: how they are shown to whoever watches them from now on (GMFB-34).
        _setMode(e.id, said['mode'] as String);
      } else if (said['away'] is bool) {
        // The app put away, or back in use: told to whoever watches them, once a change.
        e.away = said['away'] as bool;
        final away = _allAway(e.id);
        if (away == _awaySince.containsKey(e.id)) return;
        final at = _now().millisecondsSinceEpoch;
        if (away) {
          _awaySince[e.id] = at;
        } else {
          _awaySince.remove(e.id);
        }
        if (!_shown(e.id)) return;
        for (final w in [...?_watching[e.id]]) {
          _tell(w.ws, {'away': e.id, 'is': away, 'at': at});
        }
      } else if (said.containsKey('join')) {
        _join(e, said['join'], said['token'], said['ro'] is Map ? said['ro'] as Map : null);
      } else if (said.containsKey('anchor')) {
        // A read-only room's admin list, newer than the one it was joined with (an admin made or taken away).
        final name = said['anchor'];
        final room = name is String && e.rooms.contains('ro:$name') ? _rooms['ro:$name'] : null;
        if (room != null) _takeGrants(room, said);
      } else if (said.containsKey('leave')) {
        final room = said['leave'];
        if (room is String) {
          final key = _keyIn(e, room);
          if (e.rooms.contains(key)) _leave(e, key);
        }
      } else if (said.containsKey('look')) {
        _look(e, said['look'], said['token']);
      } else if (said.containsKey('unlook')) {
        final room = said['unlook'];
        if (room is String) _unlook(e, room);
      }
    }, onDone: leave, onError: (_) => leave(), cancelOnError: true);
  }

  /// A binary message from [from], routed by its first byte ([toPeer], [toRoom], [toRoomKept], [toRoomReaction]). What
  /// is passed on has the sender's name (16 bytes) put in by the hub, so nobody can send under another's. A packet to
  /// one person is answered `{ack: seq, here: bool}` or `{nak: seq, err: 'full'}`; a packet to a room is not answered.
  void _packet(_End from, List<int> data) {
    if (data.length > maxPacket + 32 || data.isEmpty) {
      from.ws.close(WebSocketStatus.messageTooBig, 'too big');
      return;
    }
    if (data[0] == toPeer && data.length > 21) {
      // [1][a number the sender made, 4 bytes][to, 16 bytes][the packet]
      final seq = ByteData.sublistView(Uint8List.fromList(data.sublist(1, 5))).getUint32(0);
      final to = hexOf(data.sublist(5, 21));
      final frame = Uint8List.fromList([toPeer, ..._unhex(from.id), ...data.sublist(21)]);
      // To every device of theirs that is here (but the one sending it, where they write to themselves).
      final there = [for (final t in _here[to] ?? const <_End>[]) if (!identical(t, from) && t.ws.isOpen) t];
      if (there.isNotEmpty) {
        // To its own name: each device that asked is told which device sent it ([toPeerFromDevice]).
        final own = to == from.id ? from.device : null;
        for (final t in there) {
          t.ws.add(_forDevice(t, frame, own));
        }
        _tell(from.ws, {'ack': seq, 'here': true});
        return;
      }
      // Nobody of that name is here. Where their home record names another relay it is passed to that relay, and the
      // sender told what that relay said (`fed` in the answer says it went that way); never what an account sends its
      // own name (federation.dart).
      final fed = federation;
      // `waiting`: it is kept on this relay until theirs is reached, not taken there yet (the app sends it again less
      // often meanwhile: what waits is each sender's own share).
      if (fed != null && to != from.id && fed.pass(to, from.id, data.sublist(21), (here, [err]) => _tell(from.ws, err != null ? {'nak': seq, 'err': err} : {'ack': seq, 'here': here == true, 'fed': true, if (here == null) 'waiting': true}), place: from.place)) return;
      if (!_hold(to, frame, byDevice: to == from.id && from.device.isNotEmpty ? from.device : null)) {
        _tell(from.ws, {'nak': seq, 'err': 'full'});
        return;
      }
      _tell(from.ws, {'ack': seq, 'here': false});
    } else if (data[0] == toRoomReaction && data.length > 17) {
      // [4][the room, 16 bytes][a sealed reaction]: kept, and to everyone else in it, whoever may post there.
      if (data.length - 17 > maxReaction) return;
      final name = hexOf(data.sublist(1, 17));
      final key = _keyIn(from, name);
      final room = _rooms[key];
      if (room == null || !(room.members[from.id]?.contains(from) ?? false)) return;
      final frame = Uint8List.fromList([toRoomReaction, ...data.sublist(1, 17), ..._unhex(from.id), ...data.sublist(17)]);
      _keep(key, room.hash, frame);
      for (final m in room.members.values.expand((d) => d).toList()) {
        if (!identical(m, from) && m.ws.isOpen) m.ws.add(frame);
      }
    } else if ((data[0] == toRoom || data[0] == toRoomKept) && data.length > 17) {
      // [2][the room, 16 bytes][the packet]: to everyone else in it.
      final name = hexOf(data.sublist(1, 17));
      final key = _keyIn(from, name);
      final room = _rooms[key];
      if (room == null || !(room.members[from.id]?.contains(from) ?? false)) return;
      final frame = Uint8List.fromList([toRoom, ...data.sublist(1, 17), ..._unhex(from.id), ...data.sublist(17)]);
      // A read-only room: someone who may not post keeps nothing in it, and what else they say (who they are, asking
      // for what was missed) reaches only those who may.
      final reader = room.owner != null && !room.writers.contains(from.id);
      if (reader && data[0] == toRoomKept) {
        _tell(from.ws, {'room': name, 'ro': 'refused'});
        return;
      }
      if (data[0] == toRoomKept) _keep(key, room.hash, frame);
      // To every device of everyone in it, the sender's other devices too, but not the connection it came from.
      for (final e in room.members.entries.toList()) {
        if (reader && !room.writers.contains(e.key)) continue;
        for (final m in e.value.toList()) {
          if (!identical(m, from) && m.ws.isOpen) m.ws.add(frame);
        }
      }
    }
  }

  /// Hands [frames] to [socket] in order, written only as fast as the connection takes them (found in the second review,
  /// 2026-11-23): a room's kept messages (up to 300 of 64 KB) and what was held for someone, written in one go, waited in
  /// memory all at once, and a phone reading them as fast as they came was ended for it. They are the hub's own already
  /// (kept in the room, or just taken from the mailbox), so nothing more is held while they wait. [notGiven] is told how
  /// many at the end were not written by the time the connection closed. What else is said to the connection meanwhile
  /// goes at once, as ever.
  /// [gone] is told of each frame, in order, as it leaves the hub's keeping: written, or (on a connection that isn't a
  /// WebSocket) lost with a connection already closed.
  void _handOver(HubSocket socket, List<Uint8List> frames, {void Function(int left)? notGiven, void Function()? gone}) {
    if (frames.isEmpty) return;
    if (socket is _WebSocketHubSocket) return socket.handOver(frames, notGiven, gone);
    for (final f in frames) {
      if (socket.isOpen) socket.add(f);
      gone?.call();
    }
  }

  /// What was held for [to] and handed to a connection that closed before it was written goes back where it was kept,
  /// before anything kept since, as far as there is room (the oldest of it left out where there isn't).
  void _holdAgain(String to, List<_Held> items) {
    final box = _mail[to] ??= [];
    var size = box.fold<int>(0, (n, h) => n + h.frame.length);
    final back = <_Held>[];
    for (final h in items.reversed) {
      if (box.length + back.length >= mailboxFrames || size + h.frame.length > mailboxBytes || _held + h.cost > heldBytes) break;
      back.insert(0, h);
      size += h.frame.length;
      _held += h.cost;
    }
    items.sublist(0, items.length - back.length).forEach(_unstore);
    box.insertAll(0, back);
    if (box.isEmpty) _mail.remove(to);
  }

  /// Keeps [frame] for [to], who is not here, where there is room: at most [mailboxFrames] and [mailboxBytes] for one
  /// person and [heldBytes] for everyone together (each packet counted with [heldOverhead]). False where there is none.
  /// [byDevice]: the device that sent it to its own name, which is not handed it back.
  bool _hold(String to, Uint8List frame, {String? byDevice}) {
    final box = _mail[to] ??= [];
    final size = box.fold<int>(0, (n, h) => n + h.frame.length);
    if (box.length >= mailboxFrames || size + frame.length > mailboxBytes || _held + _Held.costOf(frame) > heldBytes) {
      if (box.isEmpty) _mail.remove(to);
      return false;
    }
    final h = _Held(frame, _now(), byDevice: byDevice);
    h.seq = _store?.addMail(to, h.at, byDevice, frame) ?? 0;
    box.add(h);
    _held += h.cost;
    // Their app is closed: woken where it can be (an iPhone's push; an Android phone looks for itself).
    pushes?.held(to);
    return true;
  }

  /// A packet another relay passed here for [to], as from [from] (federation.dart, which has checked that relay speaks
  /// for them): handed to every device of theirs that is here, or kept for them, exactly as one from a connection
  /// here is, under the same limits. True where a device took it, false where it is kept, null where there is no room.
  bool? deliver(String to, String from, List<int> packet) {
    if (!_hex(to, 32) || !_hex(from, 32) || packet.isEmpty || packet.length > maxPacket + 32) return null;
    final frame = Uint8List.fromList([toPeer, ..._unhex(from), ...packet]);
    final there = [for (final t in _here[to] ?? const <_End>[]) if (t.ws.isOpen) t];
    if (there.isNotEmpty) {
      for (final t in there) {
        t.ws.add(frame);
      }
      return true;
    }
    return _hold(to, frame) ? false : null;
  }

  /// Tells whoever looks at [name] with its token who is in it now.
  void _showLookers(String name) {
    final lookers = _lookers[name];
    if (lookers == null) return;
    final room = _rooms[name];
    for (final l in lookers.entries.toList()) {
      if (room != null && room.hash != l.value) continue;
      _tell(l.key.ws, {'room': name, 'look': [...?room?.members.keys]});
    }
  }

  /// `{look: room, token}`: [e] is told who is in the room now (`{room, look: [names]}`) and whenever that changes,
  /// without joining it. With a token that is not the room's it is told nothing, now or later.
  void _look(_End e, Object? name, Object? token) {
    if (!_hex(name, 32) || !_hex(token, 64)) return;
    if (e.looks.length >= maxLooks && !e.looks.contains(name)) return;
    final hash = hexOf(sha256(utf8.encode(token as String)));
    (_lookers[name as String] ??= {})[e] = hash;
    e.looks.add(name);
    final room = _rooms[name];
    if (room == null || room.hash == hash) _tell(e.ws, {'room': name, 'look': [...?room?.members.keys]});
  }

  /// `{unlook: room}`: [e] stops being told who is in the room.
  void _unlook(_End e, String name) {
    e.looks.remove(name);
    final lookers = _lookers[name];
    lookers?.remove(e);
    if (lookers != null && lookers.isEmpty) _lookers.remove(name);
  }

  /// `{join: room, token, ro?}`: puts [e] in the room, making it where it is new (its token is then this one). Answered
  /// `{room, ok: true, members, ro?}` and handed what the room kept, or `{room, ok: false, err}`: `bad room`,
  /// `bad anchor` (a read-only room whose name is not made from the owner's key), `refused` (wrong token, or already in
  /// the other room of this name) or `full`. The others in it are told `{room, came}`.
  void _join(_End e, Object? name, Object? token, [Map? ro]) {
    if (!_hex(name, 32) || !_hex(token, 64)) {
      _tell(e.ws, {'room': name, 'ok': false, 'err': 'bad room'});
      return;
    }
    // A read-only room: its name must be the one made from the owner's key it is joined with.
    String? owner;
    if (ro != null) {
      final base = ro['base'], key = ro['owner'];
      if (!_hex(base, 32) || !_hex(key, 66) || !(key as String).startsWith(RegExp('0[23]')) || anchoredName(_unhex(base as String), _unhex(key)) != name) {
        _tell(e.ws, {'room': name, 'ok': false, 'err': 'bad anchor'});
        return;
      }
      owner = key;
    }
    final at = _keyOf(name as String, owner != null);
    // In one of a name's two rooms at a time.
    if (e.rooms.contains(_keyOf(name, owner == null))) {
      _tell(e.ws, {'room': name, 'ok': false, 'err': 'refused'});
      return;
    }
    final hash = hexOf(sha256(utf8.encode(token as String)));
    var room = _rooms[at];
    if (room == null) {
      if (_rooms.length >= maxRooms) {
        _tell(e.ws, {'room': name, 'ok': false, 'err': 'full'});
        return;
      }
      room = _rooms[at] = _Room(hash, owner: owner);
    }
    if (room.hash != hash || (room.members.length >= maxRoom && !room.members.containsKey(e.id))) {
      _tell(e.ws, {'room': name, 'ok': false, 'err': room.hash != hash ? 'refused' : 'full'});
      return;
    }
    final others = room.members.keys.where((id) => id != e.id).toList();
    // Every device of a member is in the room, each handed what is sent there (Matt, 2026-11-18: his phone stopped
    // seeing a circle's messages and members once his computer, the same identity, joined its rooms and took the one
    // place a member had). The others hear that someone came only with their first device.
    final devices = room.members.putIfAbsent(e.id, () => <_End>[]);
    final first = devices.isEmpty;
    if (!devices.any((d) => identical(d, e))) devices.add(e);
    e.rooms.add(at);
    if (ro != null) _takeGrants(room, ro);
    _tell(e.ws, {'room': name, 'ok': true, 'members': others, if (room.owner != null) 'ro': room.writers.contains(e.id) ? 'writer' : 'reader', 'ice': ?turn.serverFor(e.id, _now())});
    // What the room kept, for one who knows its token: written while this device was away.
    final kept = _kept[at];
    if (kept != null && kept.hash == hash) {
      final cutoff = _now().subtract(roomKeepFor);
      _handOver(e.ws, [for (final h in kept.frames) if (h.at.isAfter(cutoff)) h.frame]);
    }
    if (first) {
      for (final id in others) {
        for (final d in [...?room.members[id]]) {
          _tell(d.ws, {'room': name, 'came': e.id});
        }
      }
    }
    if (owner == null) _showLookers(name);
    _say('${e.id.substring(0, 6)} joined ${owner == null ? '' : 'read-only '}room ${name.substring(0, 6)} (${room.members.length} in it)');
  }

  /// [e] out of the room kept under [key] (a read-only room's is `ro:` and its name).
  void _leave(_End e, String key) {
    final name = _nameOf(key);
    e.rooms.remove(key);
    final room = _rooms[key];
    final devices = room?.members[e.id];
    if (room == null || devices == null || !devices.any((d) => identical(d, e))) return;
    devices.removeWhere((d) => identical(d, e));
    // Another device of theirs is still in it: they have not gone.
    if (devices.isNotEmpty) return;
    room.members.remove(e.id);
    if (room.members.isEmpty) {
      _rooms.remove(key);
    } else {
      for (final m in room.members.values.expand((d) => d).toList()) {
        _tell(m.ws, {'room': name, 'went': e.id});
      }
    }
    if (key == name) _showLookers(name);
    _say('${e.id.substring(0, 6)} left room ${name.substring(0, 6)}');
  }

  /// Forgets packets held for someone longer than [holdFor], and those a room kept longer than [roomKeepFor].
  void sweep() {
    final keptCutoff = _now().subtract(roomKeepFor);
    for (final name in _kept.keys.toList()) {
      final box = _kept[name]!;
      while (box.frames.isNotEmpty && !box.frames.first.at.isAfter(keptCutoff)) {
        final gone = box.frames.removeAt(0);
        _keptBytes -= gone.frame.length;
        _unstore(gone);
      }
      if (box.frames.isEmpty) _kept.remove(name);
    }
    final cutoff = _now().subtract(holdFor);
    for (final id in _mail.keys.toList()) {
      final box = _mail[id]!;
      for (final h in box.where((h) => !h.at.isAfter(cutoff)).toList()) {
        box.remove(h);
        _held -= h.cost;
        _unstore(h);
      }
      if (box.isEmpty) _mail.remove(id);
    }
  }
}

/// A connection as the hub holds it, whatever carries it: a WebSocket, or anything else that passes strings and bytes.
abstract class HubSocket {
  /// What the other end says: a String or a `List<int>`. Done when it has gone.
  Stream<Object?> get incoming;

  /// Says a String or a `List<int>` to the other end.
  void add(Object data);

  /// Whether the other end can still be said to.
  bool get isOpen;

  /// Closes it, with a WebSocket's number and reason for closing where there is a use for them. [incoming] is done
  /// once it has closed, whichever end closed it.
  Future<void> close([int? code, String? reason]);
}

/// A WebSocket as the hub holds it ([Hub.accept]).
class _WebSocketHubSocket implements HubSocket {
  _WebSocketHubSocket(this._ws) : _share = wireHoldOf[_ws] {
    _ws.done.then((_) => _letGo(), onError: (_) => _letGo());
  }
  final WebSocket _ws;

  /// Its share of the relay's budget (ws_door.dart): what waits to go out to it.
  final WireHold? _share;

  /// What the hub is handing it of what it keeps, a batch at a time, in order ([Hub._handOver]); and, behind a hand-over
  /// under way, the frames said to it meanwhile (`live`), so nothing said live overtakes what it is being handed (found
  /// in the third review, 2026-11-23: a deletion said live came before the kept message it deleted).
  final Queue<({Queue<Uint8List> frames, void Function(int left)? notGiven, void Function()? gone, bool live})> _handing = Queue();

  /// Whether the hub has closed it: Dart says a WebSocket is open until the far end answers its Close, but nothing more
  /// may be written to it from then on (found in the third review: a hand-over wrote to a connection closed for its
  /// replacement, and the frame it had taken was lost).
  bool _closing = false;

  @override
  Stream<Object?> get incoming => _ws;

  @override
  void add(Object data) {
    if (_closing) return;
    if (_handing.isNotEmpty && data is List<int>) {
      // Behind the hand-over under way, in order, and counted.
      final frame = data is Uint8List ? data : Uint8List.fromList(data);
      final last = _handing.last;
      if (last.live) {
        last.frames.add(frame);
      } else {
        _handing.add((frames: Queue.of([frame]), notGiven: null, gone: null, live: true));
      }
      _share?.behind(frame.length);
      return;
    }
    try {
      _ws.add(data);
    } catch (_) {}
  }

  @override
  bool get isOpen => !_closing && _ws.readyState == WebSocket.open;

  @override
  Future<void> close([int? code, String? reason]) {
    if (!_closing) {
      _closing = true;
      // What wasn't handed over goes back to whoever handed it (what was held is kept again) before anything replaces
      // this connection: the hub closes an old connection before a new one takes what is held.
      _letGo();
    }
    return _ws.close(code, reason);
  }

  void handOver(List<Uint8List> frames, void Function(int left)? notGiven, [void Function()? gone]) {
    if (_closing) {
      notGiven?.call(frames.length);
      return;
    }
    _handing.add((frames: Queue.of(frames), notGiven: notGiven, gone: gone, live: false));
    if (_handing.length == 1) _go();
  }

  /// Writes what is being handed over while what waits to go out is small and the relay has room; else waits for it.
  void _go() {
    final share = _share;
    while (_handing.isNotEmpty) {
      if (!isOpen || (share != null && share.gone)) return _letGo();
      final batch = _handing.first;
      if (batch.frames.isEmpty) {
        _handing.removeFirst();
        continue;
      }
      if (share != null && !share.hasRoom) return share.whenRoom(_go);
      final frame = batch.frames.removeFirst();
      if (batch.live) share?.unqueued(frame.length);
      try {
        _ws.add(frame);
      } catch (_) {
        // Its sink closed under it: the frame goes back with the rest.
        batch.frames.addFirst(frame);
        if (batch.live) share?.behind(frame.length);
        return _letGo();
      }
      batch.gone?.call();
    }
  }

  /// The connection is gone, or closing: whoever handed something over is told how much wasn't written; what was said
  /// live behind it goes with the connection, as anything said to a connection that goes does.
  void _letGo() {
    final left = _handing.toList();
    _handing.clear();
    for (final b in left) {
      if (b.live) {
        var n = 0;
        for (final f in b.frames) {
          n += f.length;
        }
        _share?.unqueued(n);
      } else if (b.frames.isNotEmpty) {
        b.notGiven?.call(b.frames.length);
      }
    }
  }
}

/// One connection signed in: a device of [id]'s, with the rooms it is in, the names it watches and the rooms it looks
/// at without being in them.
class _End {
  _End(this.id, this.ws, this.tell, {this.device = '', this.place = '', this.stamps = false});

  /// Whether it asked to be told which of its name's devices sent what its name sends itself ([Hub.toPeerFromDevice]).
  final bool stamps;

  /// Where it came from, as allowances count it ([Hub.placeOf]); '' for a connection made in this program.
  final String place;
  final String id;
  final HubSocket ws;

  /// Which of its name's devices this is, as it said; empty from an app from before devices.
  final String device;

  /// Whether this device has the app put away.
  bool away = false;

  /// Says something to this connection, as JSON.
  final void Function(Map<String, Object?>) tell;
  final Set<String> rooms = {};
  final Set<String> watches = {};
  final Set<String> looks = {};
}

/// A packet held for someone away or kept by a room, as it will be handed over, and when it came.
class _Held {
  _Held(this.frame, this.at, {this.byDevice});
  final Uint8List frame;
  final DateTime at;

  /// Its number in the store ([Hub.keepHeld]), to take it off the disk by; 0 where it isn't kept there.
  int seq = 0;

  /// What this counts as against [Hub.heldBytes]: its bytes and what holding it costs.
  int get cost => costOf(frame);
  static int costOf(Uint8List frame) => frame.length + Hub.heldOverhead;

  /// For a packet an identity sent to its own name: which of its devices sent it (its hello's `device`). That device
  /// isn't handed it back: it is kept for the identity's other devices (GMFB-26, an app passing on a packet it couldn't
  /// open, for a sibling that can). Null for anything else.
  final String? byDevice;
}

/// A room while someone is in it: who, and for a read-only room whose it is and who may post.
class _Room {
  _Room(this.hash, {this.owner}) : ownerId = owner == null ? '' : Hub.nameOf(Hub._unhex(owner)) {
    if (owner != null) writers.add(ownerId);
  }

  /// SHA-256 of the room's token, in hex.
  final String hash;

  /// A read-only room's circle owner (their public key, 33 bytes in hex) and name; null for an ordinary room.
  final String? owner;
  final String ownerId;

  /// Who may post in a read-only room: the owner and the admins they signed.
  final Set<String> writers = {};

  /// The generation of the admin list [writers] came from; -1 before any.
  int gv = -1;
  /// Each member by name, with every device of theirs in the room.
  final Map<String, List<_End>> members = {};
}
