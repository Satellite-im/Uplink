import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'sha256.dart';
import 'texts.dart';

/// The handles people linked: where someone who has the app says "this Discord, Telegram, X, Bluesky, Mastodon or
/// GitHub account is mine", and where someone else who asked to be told hears that they joined (Matt, 2026-11-14:
/// "Add a 'me' section to settings and allow linking popular social like telegram, discord, x, etc to be notified
/// when one of your friends or followers joins ghost messaging"; docs/me.md in the app).
///
/// It is the first thing on this server that is about who someone is, so it is opt-in at every step, and it keeps
/// as little as it can:
///
/// - **Who.** The hub's own name for an install (hub.dart: made from a key, proved by a signature as it connects).
///   Everything here is said over that connection, so only the install itself links, lists and watches for itself.
/// - **A link** is proved, never typed and trusted. Discord and X by signing in there (OAuth: this server asks them
///   who signed in); Telegram by its login widget (signed with our bot's token); Bluesky, Mastodon and GitHub by a
///   code this server makes up, put in the account's public profile and read back from the network's own public
///   API. Those three have no secrets to set up, and their follow lists are public, so they can be imported.
/// - **A phone number** is a link too ("phone"), proved by a code texted to it by a service that makes and checks
///   the code itself (texts.dart; Matt, 2026-11-14: "send the text code to a number to verify so it can't be
///   spoofed"). It is the one link whose hash can be worked back, there being only so many numbers: this server
///   is to be thought of as knowing a linked number. So a number is told to nobody, listed or not ([_quiet]).
/// - **What is kept** (`handles.json`): for each install, per network, the SHA-256 of the handle and of the account's
///   number there, and the day. Never the handle itself, a name, a token, or anything else the network said. A watch
///   list is kept as the same hashes. So this file says "this install has some Discord account" and nothing about
///   which, to anyone who does not already know the handle to hash.
/// - **Listed** is a switch, off until the person turns it on. Only a listed install's links are told to anyone.
/// - **Joined.** When a listed link is made (or a linked install turns listing on), every install watching for that
///   handle's hash is told the hash. It knows which handle that is; this server never says. Someone not connected is
///   told when they next are (at most [maxPending] kept).
///
/// What it can see beyond the hub: that an install has an account on a network, and how many handles another is
/// watching for. What it cannot do: tell anyone a person's number, key or name. None of those are here.
class Handles {
  Handles({this.dataDir, this.config = const HandlesConfig(), Fetch? fetch, DateTime Function()? now, Random? random, TextCodes? texts, this.verbose = false})
      : _fetch = fetch ?? defaultFetch,
        _now = now ?? DateTime.now,
        _random = random ?? Random.secure(),
        _texts = texts ?? (config.texts ? TwilioVerify(fetch ?? defaultFetch, sid: config.twilioSid, token: config.twilioToken, service: config.twilioVerify) : null);

  /// Where `handles.json` is kept; null keeps nothing across restarts.
  final Directory? dataDir;
  final HandlesConfig config;
  final bool verbose;
  final Fetch _fetch;
  final DateTime Function() _now;
  final Random _random;

  /// Who texts a number its code; null where that is not set up, and a number cannot be linked.
  final TextCodes? _texts;

  /// Every network a link may be on (`p` in a message). [_signIn]: proved by signing in there, in a browser.
  /// [_proof]: proved by a code put in the account's public profile.
  static const networks = ['discord', 'telegram', 'x', 'bluesky', 'mastodon', 'github', 'phone'];
  static const _signIn = {'discord', 'telegram', 'x'};
  static const _proof = {'bluesky', 'mastodon', 'github'};

  /// Linked, and told to nobody: see the class's words on a phone number.
  static const _quiet = {'phone'};

  /// [maxWatch]: the most handles one install may watch for. [maxPending]: the most joinings kept for one that is away.
  /// [maxFollows]: the most handles an import of who someone follows hands back. [stateLife]: how long a sign-in
  /// started in the app may take to finish in the browser.
  static const maxWatch = 5000;
  static const maxPending = 300;
  static const maxFollows = 5000;
  static const stateLife = Duration(minutes: 10);

  /// How many proofs, checks and imports one install may ask for in an hour: each makes this server fetch from
  /// someone else's.
  static const fetchesAnHour = 40;

  /// Texts cost money, and reach a phone whose owner may not have asked: how many codes one install may ask for,
  /// and one number be sent whoever asks, in an hour and in a day. (All installs together: [HandlesConfig.textsADay].)
  static const textsAnHour = 3;
  static const textsADay = 6;

  /// How many codes one install may try in an hour, and how long one is good for at the service.
  static const triesAnHour = 10;
  static const codeLife = Duration(minutes: 10);

  /// install -> network -> {k: the handle's hash, a: the account's hash, at: the day}
  final Map<String, Map<String, Map<String, String>>> _links = {};
  // [_listed]: installs that turned listing on. [_watch]: install -> the handle hashes it watches for. [_pending]:
  // install -> hashes that joined while it was away, told at its next hello.
  final Set<String> _listed = {};
  final Map<String, Set<String>> _watch = {};
  final Map<String, List<String>> _pending = {};

  /// Usernames (Matt, 2026-11-14: "create a profile and username under "me" to register a username and add friends
  /// on the platform"): the SHA-256 of a username ([nameKey]) -> {id: the install, key: its public key in base64,
  /// at: the day}. Looking one up hashes what was typed. An install has one. The username itself is kept apart, in
  /// [_shown], for the admin page alone (since 2026-11-19).
  final Map<String, Map<String, String>> _names = {};
  // install -> the hash of the username it holds.
  final Map<String, String> _nameOf = {};

  /// What each install keeps here for itself, sealed with a key only it has: Uplink's own lists of what was archived
  /// or deleted where the network itself could not do it (Matt, 2026-11-15: "add them to a ignore or archive list on
  /// my ghost account specifically"). This server can't read it; one blob per install, [maxKept] at most.
  final Map<String, String> _kept = {};
  static const maxKept = 256 * 1024;

  /// The third-party sign-in cookies ("cURL entries") a Chrome extension captures and the app's devices sign in with
  /// (Matt, 2026-11-21: "make a chrome plugin ... getting all the curl keys ... sync the cURL entries across all
  /// devices so we don't need to login to things like instagram on every device"). Sealed with a key only the
  /// account's devices have (derived from the backup's kept_key); this server can't read it. One blob per identity,
  /// so all of an account's devices share the one slot, [maxCurl] at most.
  final Map<String, String> _curl = {};
  static const maxCurl = 128 * 1024;

  /// The public key each connected install proved itself with (hub.dart), for the username it claims.
  /// Kept while any of the identity's connections is here ([_conns] counts them: an account's devices connect as one
  /// identity with one key), and forgotten with the last, so it doesn't grow with everyone who ever connected.
  final Map<String, String> _keys = {};
  final Map<String, int> _conns = {};

  /// When each identity looked someone up, so the usernames cannot be walked through. An account's devices sign in as
  /// one identity, so its devices share the [lookupsAnHour] (the app holds what it looks up of its own accord, the name
  /// watch's lookups and the friend requests' checks, to a quarter of them, shared out among the account's devices:
  /// lib/me/lookup_budget.dart).
  final Map<String, List<DateTime>> _lookups = {};
  static const lookupsAnHour = 120;

  /// Badge questions ('badges') by each id in the last hour, and how many ids and usernames one may ask of.
  final Map<String, List<DateTime>> _badgeAsks = {};
  static const badgesAnHour = 240;
  static const badgesAtOnce = 64;

  /// What a sign-in that finished while its install was away has to tell it: install -> [{p, handle, k}].
  final Map<String, List<Map<String, String>>> _done = {};

  // --- souls, special badges and the admin page (Matt, 2026-11-19: "Build a new points system into the app called
  // souls ... give them out as rewards to people who submit bugs ... a simple admin page for me to login to ... allow
  // me to see all users who signed up on the relay and issue special badges and souls") ----------------------------

  /// Each username as it was claimed, by its hash: the admin's list of who signed up names them. Before 2026-11-19
  /// only the hash was kept; an install says its own username as it says hello, and it is taken where it hashes to the
  /// one that install holds.
  final Map<String, String> _shown = {};

  /// The usernames each install held before its present one, newest last, at most [wasKept] (Matt, 2026-11-20: "add the
  /// ability to tie users names to their accounts when they sign back in later or reconnect to the app so that we can give
  /// out bug bounties properly"): a ticket filed under a name since given up still finds its person.
  final Map<String, List<String>> _was = {};
  static const wasKept = 10;

  /// The Uplink account an install's identity belongs to (relay/lib/accounts.dart, Accounts.accountOf), for the admin page:
  /// the same person across a reinstall or another device, where they signed back in to it. Set by bin/relay.dart.
  String? Function(String id)? accountOf;

  /// [name] said in words (a lookup, a sign-in by username, a hello): where it is a username held here, the admin page
  /// can show it from now on. The directory itself keeps only its hash.
  void learnName(String name) {
    if (!goodName(name)) return;
    final k = nameKey(name);
    if (_names[k] == null || _shown[k] == tidyName(name)) return;
    _shown[k] = tidyName(name);
    _changed();
  }

  /// For a test: [id]'s username as though it were claimed on an app that never said it.
  void forgetShownForTest(String id) {
    final k = _nameOf[id];
    if (k != null) _shown.remove(k);
  }

  /// Keeps [k]'s shown name as one [id] held before.
  void _remember(String id, String? k) {
    final name = k == null ? null : _shown[k];
    if (name == null) return;
    final list = _was[id] ??= [];
    list
      ..remove(name)
      ..add(name);
    if (list.length > wasKept) list.removeAt(0);
  }

  /// Souls by install, and its special badges (ids from [specialBadges]).
  final Map<String, int> _souls = {};
  final Map<String, List<String>> _special = {};

  /// The one badge each person shows beside their name, of those they have (Matt, 2026-11-20: "allow the user to choose
  /// one badge to showcase next to their names don't show them all"); their highest where they chose none.
  final Map<String, String> _showcase = {};

  /// The badge [id] shows beside their name: the one they chose while they have it, else their first; null for none.
  String? showcaseOf(String id) {
    final have = _special[id];
    if (have == null || have.isEmpty) return null;
    final chosen = _showcase[id];
    if (chosen != null && have.contains(chosen)) return chosen;
    return [for (final b in specialBadges) if (have.contains(b)) b].firstOrNull ?? have.first;
  }

  /// Souls and badges given that the person's app has not yet said it showed them, by install, oldest first, at most
  /// [unseenKept] each: {g (an id), at, souls or badge, why} (Matt, 2026-11-21: "notify a user when they have recieved
  /// souls wiht a description for why like "bug bounty" etc it should notify them next time they connect to the app
  /// (or immediatly if they're connected in real time)"). Said with the gift where they are connected, and again at
  /// every hello until the app says `souls-seen`.
  final Map<String, List<Map<String, Object?>>> _unseen = {};
  static const unseenKept = 50;

  /// What the admin gave, newest last, at most [grantsKept]: {at, to, souls or badge, why}.
  final List<Map<String, Object?>> _grants = [];
  static const grantsKept = 2000;

  /// Signed in to the admin page, per connection: each connection's own tell (the `e.tell` hub.dart has for it) and when
  /// it signed in. A good admin-login adds the asking tell; went(id, tell) removes that tell whether or not it is
  /// _here[id]; a restart forgets them all. Before 2026-11-20 a sign-in was the identity's, answered on whichever of its
  /// connections came last and kept while any stayed: the Marketplace's review rides on it (market.dart), so it is now
  /// the connection's that signed in, and it ages ([adminSignedIn]).
  final Map<String, Map<void Function(Map<String, Object?>), DateTime>> _adminConns = {};

  /// How long a sign-in to the admin page lasts on its connection.
  static const adminLife = Duration(hours: 8);

  /// When each install tried to sign in to the admin page, so a password can't be guessed at.
  final Map<String, List<DateTime>> _adminTries = {};
  static const adminTriesAnHour = 5;

  /// The special badges the admin may give, by id (the app draws each: lib/ui/special_badges.dart).
  static const specialBadges = {'bughunter', 'alpha', 'founder', 'team', 'supporter', 'helper'};

  /// The most souls one grant gives or takes.
  static const soulsAtOnce = 100000;

  /// How many souls [id] has, and the special badges it was given.
  int soulsOf(String id) => _souls[id] ?? 0;

  /// A bounty's souls, given by the bounty key (bounty.dart) as the admin page gives them: added, kept, logged with why
  /// (`by: bounty`), and told to them where they are connected. Their total after.
  int giveBounty(String to, int n, String why) {
    _souls[to] = soulsOf(to) + n;
    _grant(to, {'souls': n, 'why': why.length > 200 ? why.substring(0, 200) : why, 'by': 'bounty'});
    _changed();
    _here[to]?.call(_soulsMessage(to, got: n, why: why));
    return soulsOf(to);
  }
  List<String> specialOf(String id) => List.unmodifiable(_special[id] ?? const <String>[]);

  // --- souls sent from one person to another (GMFB-39, "Payments between friends"; Matt, 2026-11-23: "Tip souls in a
  // chat"). Souls only move here: what leaves one count arrives in the other in the same step, with a receipt, and all
  // three are written to handles.json in one file (save, a file beside renamed over), so a stop between them can't
  // make or lose a soul. The route that asks is souls_send.dart, signed by the sender's own key. ------------------------

  /// A receipt for each sending, oldest first: {id (the sender's own name for it, 32 hex), at (ms), from, to, souls}.
  /// One is kept for a day at least, since the day's limits are counted from them, and the newest [sentKept] after that.
  final List<Map<String, Object?>> _sent = [];
  final Map<String, Map<String, Object?>> _sentById = {};

  /// The most souls one sending moves, the most one person sends in any 24 hours and in how many sendings, and how
  /// many receipts are kept past their first day. (A bounty is 50 or 75 souls, 500 at most: a person can pass a
  /// bounty or two on in a day, and no more.)
  static const sendAtOnce = 100;
  static const sendADay = 300;
  static const sendsADay = 10;
  static const sentKept = 5000;

  /// Moves [n] souls from [from] to [to] under the sender's name for it, [id], once: asked again with the same [id],
  /// people and number it answers the receipt it made the first time (`again`), and moves nothing. Refused, with why
  /// in `error`, and nothing moved: `amount` (not 1 to [sendAtOnce]), `yourself`, `no_account` (the sender holds no
  /// username here), `no_receiver` (nobody with a username here has that id, so souls can't be sent into nowhere),
  /// `id_used` (that [id] was another sending's), `daily_limit`, `not_enough`.
  ///
  /// Nothing in it waits: two askings at once are taken one after the other, and the second sees what the first left.
  /// It is written to disk before this returns, so a receipt answered is a receipt kept.
  ({String? error, Map<String, Object?>? receipt, bool again}) sendSouls(String from, String to, int n, String id) {
    final before = _sentById[id];
    if (before != null) {
      if (before['from'] == from && before['to'] == to && before['souls'] == n) return (error: null, receipt: before, again: true);
      return (error: 'id_used', receipt: null, again: false);
    }
    if (n < 1 || n > sendAtOnce) return (error: 'amount', receipt: null, again: false);
    if (from == to) return (error: 'yourself', receipt: null, again: false);
    if (!holdsAName(from)) return (error: 'no_account', receipt: null, again: false);
    if (!holdsAName(to)) return (error: 'no_receiver', receipt: null, again: false);
    final now = _now().millisecondsSinceEpoch;
    var sendings = 0, souls = 0;
    for (final r in _sent.reversed) {
      if (now - (r['at'] as int) > Duration.millisecondsPerDay) break;
      if (r['from'] != from) continue;
      sendings++;
      souls += r['souls'] as int;
    }
    if (sendings >= sendsADay || souls + n > sendADay) return (error: 'daily_limit', receipt: null, again: false);
    if (soulsOf(from) < n) return (error: 'not_enough', receipt: null, again: false);
    final receipt = <String, Object?>{'id': id, 'at': now, 'from': from, 'to': to, 'souls': n};
    _souls[from] = soulsOf(from) - n;
    _souls[to] = soulsOf(to) + n;
    _sent.add(receipt);
    _sentById[id] = receipt;
    while (_sent.length > sentKept && now - (_sent.first['at'] as int) > Duration.millisecondsPerDay) {
      _sentById.remove(_sent.removeAt(0)['id']);
    }
    save();
    // Each is told their new count where they are connected; the one who got them, how many and from whom, as a
    // gift is said (an app from before this says "You got 20 souls: From maya").
    _here[from]?.call(_soulsMessage(from));
    final name = usernameOf(from);
    _here[to]?.call(_soulsMessage(to, got: n, why: name == null ? 'From a friend' : 'From $name'));
    _say('${from.substring(0, 6)} sent $n souls to ${to.substring(0, 6)}');
    return (error: null, receipt: receipt, again: false);
  }

  /// The receipt of the sending [id], for one of the two people in it ([asker]); null for anyone else, and where there
  /// is none.
  Map<String, Object?>? soulsReceipt(String id, String asker) {
    final r = _sentById[id];
    return r != null && (r['from'] == asker || r['to'] == asker) ? r : null;
  }

  /// Whether [user] and [pass] are the admin's, as [HandlesConfig.adminHash] keeps the password: `salt:hash`, the
  /// hash SHA-256 taken [adminRounds] times over the salt and the password.
  bool adminPassword(String user, String pass) {
    final want = config.adminHash;
    final at = want.indexOf(':');
    if (config.adminUser.isEmpty || at <= 0 || user != config.adminUser) return false;
    return _same(adminHashOf(want.substring(0, at), pass), want.substring(at + 1));
  }

  /// How many times over the admin's password is hashed, so each guess at a stolen hash costs that much.
  static const adminRounds = 100000;

  /// The hash kept for [pass] with [salt] (tool/admin-password.mjs makes one the same way).
  static String adminHashOf(String salt, String pass) {
    var h = sha256(utf8.encode('ghost-admin v1|$salt|$pass'));
    for (var i = 1; i < adminRounds; i++) {
      h = sha256(h);
    }
    return hexOf(h);
  }

  /// Whether [id] holds one of the admin's usernames ([HandlesConfig.adminNames]): only Matt's own account may sign in.
  bool _isAdminAccount(String id) {
    final k = _nameOf[id];
    return k != null && config.adminNames.any((n) => nameKey(n) == k);
  }

  /// Whether some connection of [id] signed in to the admin page less than [within] ago, and [id] still holds one of
  /// GHOST_ADMIN_NAMES' usernames: for the market's admin calls over HTTP (market.dart), which ask within 30 minutes for
  /// approving, listing, withdrawing and blocking.
  bool adminSignedIn(String id, {Duration within = adminLife}) {
    final conns = _adminConns[id];
    if (conns == null || !_isAdminAccount(id)) return false;
    final now = _now();
    return conns.values.any((at) => now.difference(at) < within);
  }

  /// Whether the connection [tell] of [id] signed in to the admin page less than [adminLife] ago.
  bool _adminHere(String id, void Function(Map<String, Object?>) tell) {
    final at = _adminConns[id]?[tell];
    return at != null && _now().difference(at) < adminLife && _isAdminAccount(id);
  }

  /// When [id]'s username was claimed: the day `claim` kept in `_names[k]['at']`, as UTC midnight; null without one.
  /// The Marketplace takes plugins from a username a week after this (market.dart).
  DateTime? claimedOn(String id) {
    final k = _nameOf[id];
    final at = k == null ? null : _names[k]?['at'];
    if (at == null) return null;
    final day = DateTime.tryParse('${at}T00:00:00Z');
    return day?.toUtc();
  }

  /// The username [id] holds as it was typed, where the relay has been told it (since 2026-11-19); null otherwise.
  String? usernameOf(String id) {
    final k = _nameOf[id];
    return k == null ? null : _shown[k];
  }

  /// `{"dir":"souls"}` as [id] is told it: their total, their badges and the one they show; with a gift, how many
  /// souls ([got]) or which [badge], [why], and the gift's id ([gift]) for the app to say it showed it (`souls-seen`).
  Map<String, Object?> _soulsMessage(String id, {int? got, String? why, String? badge, String? gift}) => {
        'dir': 'souls',
        'n': soulsOf(id),
        'special': specialOf(id),
        'show': ?showcaseOf(id),
        'got': ?got,
        'why': ?why,
        'badge': ?badge,
        'gift': ?gift,
      };

  /// Keeps a gift for [id] until their app has shown it; its id.
  String _keepUnseen(String id, Map<String, Object?> what) {
    final g = hexOf([for (var i = 0; i < 8; i++) _random.nextInt(256)]);
    final list = _unseen[id] ??= [];
    list.add({'g': g, 'at': _now().toUtc().toIso8601String(), ...what});
    while (list.length > unseenKept) {
      list.removeAt(0);
    }
    return g;
  }

  /// The gifts [id]'s app has not shown, as said at hello; null for none.
  Map<String, Object?>? _unseenMessage(String id) {
    final list = _unseen[id];
    if (list == null || list.isEmpty) return null;
    return {'dir': 'souls-gifts', 'list': list, 'n': soulsOf(id), 'special': specialOf(id)};
  }

  void _grant(String id, Map<String, Object?> what) {
    _grants.add({'at': _now().toUtc().toIso8601String(), 'to': id, ...what});
    while (_grants.length > grantsKept) {
      _grants.removeAt(0);
    }
  }

  /// Everyone with a username or an install known here, for the admin page: id, username (where known), the day they
  /// signed up, a verified number, the networks linked, souls, badges, and whether they are connected now.
  List<Map<String, Object?>> _everyone() {
    final ids = <String>{..._nameOf.keys, ..._souls.keys, ..._special.keys, ..._links.keys};
    final out = <Map<String, Object?>>[];
    for (final id in ids) {
      final k = _nameOf[id];
      out.add({
        'id': id,
        'name': ?(k == null ? null : _shown[k]),
        'named': k != null,
        'at': k == null ? null : _names[k]?['at'],
        'verified': phoneKeyOf(id) != null,
        'links': [for (final n in (_links[id] ?? const <String, Map<String, String>>{}).keys) if (n != 'phone') n],
        'souls': soulsOf(id),
        'special': specialOf(id),
        'here': _here.containsKey(id),
        'account': ?accountOf?.call(id),
        if (_was[id]?.isNotEmpty ?? false) 'was': _was[id],
      });
    }
    out.sort((a, b) => '${b['at'] ?? ''}'.compareTo('${a['at'] ?? ''}'));
    return out;
  }

  /// What profile codes are made with ([codeFor]): 32 random bytes in hex, made once and kept in handles.json.
  String _secret = '';

  // Made from the above as it is read and changed.
  // [_watchers]: a handle's hash -> the installs watching for it. [_account]: an account's hash -> the install it is
  // linked to. [_here]: each connected install's way to be told something. [_asked]: sign-ins started and not yet
  // finished, by their state. [_fetched]: when each install last made this server fetch ([fetchesAnHour]).
  final Map<String, Set<String>> _watchers = {};
  final Map<String, String> _account = {};
  final Map<String, void Function(Map<String, Object?>)> _here = {};
  final Map<String, _Asked> _asked = {};
  final Map<String, List<DateTime>> _fetched = {};

  // Codes by text, none of it kept: when each install asked, when each number (by its hash) was texted, when
  // anyone was, which installs a number's code was sent for, and when each tried one.
  final Map<String, List<DateTime>> _textedBy = {};
  final Map<String, List<DateTime>> _textedTo = {};
  final List<DateTime> _textedAll = [];
  final Map<String, Map<String, DateTime>> _codeFor = {};
  final Map<String, List<DateTime>> _tried = {};
  Timer? _saver;

  int get linked => _links.values.fold(0, (n, m) => n + m.length);

  /// Whether the install [id] holds the username [name]: a feedback report's name is filed as its sender's only then
  /// (feedback.dart).
  bool ownsName(String id, String name) => goodName(name) && _names[nameKey(name)]?['id'] == id;

  /// The hash of the phone number [id] verified by a texted code, or null: who may take the invites waiting for that
  /// number (invites.dart).
  String? phoneKeyOf(String id) => _links[id]?['phone']?['k'];

  /// Who [id] is beyond its key, for counting what it may leave on the relay (invites.dart): the number it verified
  /// by a texted code, else an account it linked by signing in there, else null. A fresh key costs nothing, so a limit
  /// counted by key is no limit; a number or an account costs something to have, and a new key that proves the same
  /// one is counted as the same someone. A username alone is not enough, since any new key can claim one.
  String? whoOf(String id) {
    final phone = phoneKeyOf(id);
    if (phone != null) return 'phone|$phone';
    final links = _links[id];
    if (links == null) return null;
    for (final e in links.entries) {
      final account = e.value['a'] ?? e.value['k'];
      if (account != null) return '${e.key}|$account';
    }
    return null;
  }

  int get names => _names.length;

  /// The hash a username is kept and looked up by: the same in the app (lib/me/profile.dart).
  static String nameKey(String name) => hexOf(sha256(utf8.encode('ghost-name v1|${tidyName(name)}')));

  /// A username as it is compared: lower case, no "@" in front, no spaces around.
  static String tidyName(String name) {
    var n = name.trim().toLowerCase();
    while (n.startsWith('@')) {
      n = n.substring(1);
    }
    return n;
  }

  /// Three to twenty letters, digits, dots and underscores, starting with a letter or digit; not one of [reserved].
  static bool goodName(String name) {
    final n = tidyName(name);
    return RegExp(r'^[a-z0-9][a-z0-9._]{2,19}$').hasMatch(n) && !n.contains('..') && !reserved.contains(n);
  }

  /// Usernames nobody may claim: ones that would read as the service or its staff, and a few words with a meaning of
  /// their own (everyone, here, null).
  static const reserved = {'admin', 'administrator', 'uplink', 'ghost', 'ghostmessaging', 'ghost_messaging', 'support', 'help', 'official', 'staff', 'moderator', 'mod', 'system', 'root', 'security', 'team', 'everyone', 'here', 'null', 'undefined'};
  int get listed => _listed.length;
  int get watched => _watch.values.fold(0, (n, s) => n + s.length);

  /// The hash a handle is kept and watched by: the same in the app (lib/me/me.dart).
  static String keyOf(String network, String handle) => hexOf(sha256(utf8.encode('ghost-handle v1|$network|${tidy(network, handle)}')));

  /// A handle as it is compared: no "@" in front, no spaces, lower case. A phone number: [tidyNumber].
  static String tidy(String network, String handle) {
    if (network == 'phone') return tidyNumber(handle);
    var h = handle.trim().toLowerCase();
    while (h.startsWith('@')) {
      h = h.substring(1);
    }
    return h;
  }

  /// A phone number as it is compared and texted: "+", the country's code, the digits (E.164). Ten digits, or
  /// eleven that start with 1, are read as a North American number, as people there write theirs. Empty where what
  /// was typed holds anything a number does not.
  static String tidyNumber(String typed) {
    final t = typed.trim();
    if (!RegExp(r'^\+?[0-9 ().\-]+$').hasMatch(t)) return '';
    final digits = t.replaceAll(RegExp(r'[^0-9]'), '');
    if (t.startsWith('+')) return '+$digits';
    if (digits.length == 10) return '+1$digits';
    if (digits.length == 11 && digits.startsWith('1')) return '+$digits';
    return digits;
  }

  // What a tidied handle may look like: a number in E.164, a North American one, a plain handle, a server's name.
  static final _number = RegExp(r'^\+[1-9][0-9]{7,14}$');
  static final _northAmerican = RegExp(r'^\+1[2-9][0-9]{9}$');
  static final _plain = RegExp(r'^[a-z0-9._-]{1,64}$');
  static final _host = RegExp(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*\.[a-z]{2,24}$');

  /// Whether [handle] (tidied) could be one on [network]: what is fetched is built from it.
  static bool wellFormed(String network, String handle) {
    switch (network) {
      case 'phone':
        return _number.hasMatch(handle) && (!handle.startsWith('+1') || _northAmerican.hasMatch(handle));
      case 'mastodon':
        final at = handle.indexOf('@');
        return at > 0 && _plain.hasMatch(handle.substring(0, at)) && _host.hasMatch(handle.substring(at + 1)) && handle.length <= 120;
      case 'bluesky':
        return _host.hasMatch(handle) && handle.length <= 120;
      default:
        return _plain.hasMatch(handle);
    }
  }

  void _say(String what) {
    // Never a handle, never a whole name.
    if (verbose) stdout.writeln('${_now().toIso8601String()} handles $what');
  }

  // --- what is kept ---------------------------------------------------------------------------------------------------

  File? get _file => dataDir == null ? null : File('${dataDir!.path}/handles.json');

  /// Reads handles.json, makes the profile codes' secret where there is none, and builds the lookups that are worked
  /// out from what is kept ([_account], [_watchers], [_nameOf]).
  void load() {
    final file = _file;
    try {
      if (file != null && file.existsSync()) {
        final all = jsonDecode(file.readAsStringSync()) as Map;
        _secret = (all['secret'] as String?) ?? '';
        (all['links'] as Map? ?? const {}).forEach((id, nets) {
          _links[id as String] = {for (final e in (nets as Map).entries) e.key as String: (e.value as Map).cast<String, String>()};
        });
        _listed.addAll((all['listed'] as List? ?? const []).cast<String>());
        (all['watch'] as Map? ?? const {}).forEach((id, keys) => _watch[id as String] = (keys as List).cast<String>().toSet());
        (all['pending'] as Map? ?? const {}).forEach((id, keys) => _pending[id as String] = (keys as List).cast<String>().toList());
        (all['names'] as Map? ?? const {}).forEach((k, v) => _names[k as String] = (v as Map).cast<String, String>());
        (all['kept'] as Map? ?? const {}).forEach((id, blob) => _kept[id as String] = blob as String);
        (all['curl'] as Map? ?? const {}).forEach((id, blob) => _curl[id as String] = blob as String);
        (all['shown'] as Map? ?? const {}).forEach((k, name) => _shown[k as String] = name as String);
        (all['was'] as Map? ?? const {}).forEach((id, names) => _was[id as String] = [for (final n in names as List) '$n']);
        (all['souls'] as Map? ?? const {}).forEach((id, n) => _souls[id as String] = (n as num).toInt());
        (all['special'] as Map? ?? const {}).forEach((id, list) => _special[id as String] = (list as List).cast<String>().toList());
        (all['showcase'] as Map? ?? const {}).forEach((id, b) => _showcase[id as String] = b as String);
        _grants.addAll([for (final g in (all['grants'] as List? ?? const [])) (g as Map).cast<String, Object?>()]);
        (all['unseen'] as Map? ?? const {}).forEach((id, list) => _unseen[id as String] = [for (final g in list as List) (g as Map).cast<String, Object?>()]);
        for (final r in (all['sent'] as List? ?? const [])) {
          if (r is Map && r['id'] is String && r['at'] is int && r['from'] is String && r['to'] is String && r['souls'] is int) {
            final receipt = r.cast<String, Object?>();
            _sent.add(receipt);
            _sentById[r['id'] as String] = receipt;
          }
        }
      }
    } catch (_) {
      // A file that cannot be read is started again from nothing rather than stopping the relay.
    }
    if (_secret.length != 64) _secret = hexOf([for (var i = 0; i < 32; i++) _random.nextInt(256)]);
    for (final e in _links.entries) {
      for (final link in e.value.values) {
        final a = link['a'];
        if (a != null) _account[a] = e.key;
      }
    }
    for (final e in _watch.entries) {
      for (final k in e.value) {
        (_watchers[k] ??= {}).add(e.key);
      }
    }
    for (final e in _names.entries) {
      final id = e.value['id'];
      if (id != null) _nameOf[id] = e.key;
    }
  }

  /// Writes all that is kept to handles.json now (to a file beside, renamed over).
  void save() {
    _saver?.cancel();
    _saver = null;
    final file = _file;
    if (file == null) return;
    try {
      file.parent.createSync(recursive: true);
      final tmp = File('${file.path}.tmp');
      tmp.writeAsStringSync(jsonEncode({
        'secret': _secret,
        'links': _links,
        'listed': _listed.toList(),
        'watch': {for (final e in _watch.entries) e.key: e.value.toList()},
        'pending': _pending,
        'names': _names,
        'kept': _kept,
        'curl': _curl,
        'shown': _shown,
        'was': _was,
        'souls': _souls,
        'special': _special,
        'showcase': _showcase,
        'grants': _grants,
        'unseen': _unseen,
        'sent': _sent,
      }));
      tmp.renameSync(file.path);
    } catch (_) {}
  }

  /// Something kept has changed: written within two seconds, once for a run of changes.
  void _changed() => _saver ??= Timer(const Duration(seconds: 2), save);

  /// Forgets sign-ins that were started and never finished, and codes by text that have run out.
  void sweep() {
    final now = _now();
    final cutoff = now.subtract(stateLife);
    _asked.removeWhere((_, a) => a.at.isBefore(cutoff));
    for (final lists in [_textedBy, _textedTo, _tried]) {
      lists.removeWhere((_, list) => !list.any((t) => now.difference(t) <= const Duration(days: 1)));
    }
    _codeFor.removeWhere((_, who) {
      who.removeWhere((_, at) => now.difference(at) > codeLife);
      return who.isEmpty;
    });
  }

  // --- an install comes, speaks, and goes ---------------------------------------------------------------------------

  /// The hub says [id] has connected: [tell] is how to say something to it, [key] the public key it proved. With
  /// several devices under one name, the one that came last is the one told what is not an answer.
  void came(String id, void Function(Map<String, Object?>) tell, {List<int>? key}) {
    _here[id] = tell;
    _conns[id] = (_conns[id] ?? 0) + 1;
    if (key != null) _keys[id] = base64Encode(key);
  }

  /// The hub says the connection [tell] of [id] has closed.
  void went(String id, void Function(Map<String, Object?>) tell) {
    // Signed in to the admin page for as long as that connection is here, no longer, whichever of the identity's
    // connections _here holds.
    final conns = _adminConns[id];
    if (conns != null) {
      conns.remove(tell);
      if (conns.isEmpty) _adminConns.remove(id);
    }
    if (identical(_here[id], tell)) _here.remove(id);
    final left = (_conns[id] ?? 1) - 1;
    if (left > 0) {
      _conns[id] = left;
    } else {
      _conns.remove(id);
      _keys.remove(id);
    }
  }

  /// How each network is linked here: "signin" or "proof", "text" for a phone number, or "off" where what it
  /// needs has not been set up.
  Map<String, String> get ways => {
        for (final n in networks)
          n: n == 'phone'
              ? (_texts != null ? 'text' : 'off')
              : _proof.contains(n)
                  ? 'proof'
                  : switch (n) {
                      'discord' => config.discordId.isNotEmpty && config.discordSecret.isNotEmpty,
                      'x' => config.xId.isNotEmpty,
                      _ => config.telegramBot.isNotEmpty && config.telegramToken.isNotEmpty,
                    }
                      ? 'signin'
                      : 'off',
      };

  /// Whether [list] has room for one more: fewer than [anHour] in the last hour, and than [aDay] in the last day.
  static bool _room(List<DateTime>? list, DateTime now, int anHour, int aDay) {
    if (list == null) return true;
    list.removeWhere((t) => now.difference(t) > const Duration(days: 1));
    return list.length < aDay && list.where((t) => now.difference(t) <= const Duration(hours: 1)).length < anHour;
  }

  /// Whether [id] may have this server fetch from another once more this hour ([fetchesAnHour]); counts it where so.
  bool _mayFetch(String id) {
    final now = _now();
    final list = _fetched[id] ??= [];
    list.removeWhere((t) => now.difference(t) > const Duration(hours: 1));
    if (list.length >= fetchesAnHour) return false;
    list.add(now);
    return true;
  }

  /// Something an install said that starts `{"dir": …}`. [id] is who the hub knows it to be; the answer goes to [tell],
  /// the connection that said it (hub.dart passes each its own), else to the one _here holds for [id]. So the answer to a
  /// sign-in reaches the device that asked, and two devices on one identity (a computer that became the same you as its
  /// phone) each have their own.
  Future<void> said(String id, Map said, [void Function(Map<String, Object?>)? asking]) async {
    final tell = asking ?? _here[id];
    if (tell == null) return;
    final network = said['p'];
    void err(String why) => tell({'dir': 'err', 'about': said['dir'], 'p': network, 'err': why});
    final known = network is String && networks.contains(network);
    try {
      switch (said['dir']) {
        case 'hello':
          // Said as the app connects: how each network is linked here, what this install has, and anything that
          // happened for it while it was away (a sign-in finished, someone it watches for joined).
          tell({
            'dir': 'hello',
            'ways': ways,
            'listed': _listed.contains(id),
            'links': [for (final e in (_links[id] ?? const {}).entries) {'p': e.key, 'k': e.value['k'], 'at': e.value['at']}],
            'watching': _watch[id]?.length ?? 0,
            'souls': soulsOf(id),
            'special': specialOf(id),
          });
          // Its own username, said so the admin's list can name it: kept only where it hashes to the one it holds.
          final mine = said['name'];
          final held = _nameOf[id];
          if (mine is String && goodName(mine) && held != null && nameKey(mine) == held && _shown[held] != tidyName(mine)) {
            _shown[held] = tidyName(mine);
            _changed();
          }
          // Souls and badges given while away, said until the app has shown them.
          final away = _unseenMessage(id);
          if (away != null) tell(away);
          for (final done in _done.remove(id) ?? const <Map<String, String>>[]) {
            tell({'dir': 'linked', ...done});
          }
          final waiting = _pending.remove(id);
          if (waiting != null && waiting.isNotEmpty) {
            tell({'dir': 'joined', 'list': waiting});
            _changed();
          }
        case 'keep':
          // The install's own sealed blob ([_kept]), replaced whole; an empty one forgets it. 'kept' hands it back.
          final blob = said['blob'];
          if (blob is! String || blob.length > maxKept) return err('That is more than can be kept.');
          if (blob.isEmpty) {
            _kept.remove(id);
          } else {
            _kept[id] = blob;
          }
          _changed();
          tell({'dir': 'keep', 'ok': true});
        case 'kept':
          tell({'dir': 'kept', 'blob': _kept[id]});
        case 'curl-keep':
          // Keeps the account's sealed sign-in cookies in its one slot, in place of what was there; an empty one
          // clears it.
          final blob = said['blob'];
          if (blob is! String || blob.length > maxCurl) return err('That is more than can be kept.');
          if (blob.isEmpty) {
            _curl.remove(id);
          } else {
            _curl[id] = blob;
          }
          _changed();
          tell({'dir': 'curl-keep', 'ok': true});
        case 'curl-kept':
          // What is kept in that slot, as it was given; null for nothing.
          tell({'dir': 'curl-kept', 'blob': _curl[id]});
        case 'name':
          // Whether this install has a username here: its hash, and its letters where this server has them (said with a
          // hello or a claim, for the admin's page), so an app that moved here from another relay, or whose account
          // claimed it on another device, can show the name it holds here (GMFB-25).
          final mine = _nameOf[id];
          tell({'dir': 'name', 'k': mine, 'n': ?(mine == null ? null : _shown[mine])});
        case 'claim':
          // Takes a username for this install, giving up the one it had; refused as taken where another holds it.
          final name = said['name'];
          if (name is! String || !goodName(name)) return err('A username is 3 to 20 letters, numbers, dots or underscores.');
          final key = _keys[id];
          if (key == null) return err('Connect again, then try.');
          final k = nameKey(name);
          final held = _names[k];
          if (held != null && held['id'] != id) return tell({'dir': 'claim', 'name': tidyName(name), 'ok': false, 'err': 'taken'});
          final before = _nameOf[id];
          if (before != null && before != k) _names.remove(before);
          // Claiming the name it holds again (a profile saved again) keeps the day it was first claimed: the
          // Marketplace's week from it can't be started over by accident (market.dart, claimedOn).
          final day = held != null && held['id'] == id && held['at'] != null ? held['at']! : _now().toUtc().toIso8601String().substring(0, 10);
          _names[k] = {'id': id, 'key': key, 'at': day};
          _nameOf[id] = k;
          if (before != null && before != k) {
            _remember(id, before);
            _shown.remove(before);
          }
          _shown[k] = tidyName(name);
          _changed();
          tell({'dir': 'claim', 'name': tidyName(name), 'ok': true, 'k': k});
        case 'release':
          // Gives up this install's username: anyone may claim it from now on.
          final k = _nameOf.remove(id);
          if (k != null) {
            _remember(id, k);
            _names.remove(k);
            _shown.remove(k);
          }
          _changed();
          tell({'dir': 'released'});
        case 'whois':
          // Who holds a username: their hub name and public key, which is all it takes to write to them.
          final name = said['name'];
          if (name is! String || !goodName(name)) return tell({'dir': 'whois', 'name': name, 'none': true});
          if (!mayLookUp(id)) return err('Too many lookups. Try again in a while.');
          final found = _names[nameKey(name)];
          if (found == null) return tell({'dir': 'whois', 'name': tidyName(name), 'none': true});
          // Looked up in words: the admin page can name its holder from now on, an install on an older app that never
          // says its own name too.
          learnName(name);
          tell({'dir': 'whois', 'name': tidyName(name), 'id': found['id'], 'key': found['key']});
        case 'badges':
          // Which of these verified a phone number by a texted code: the verified-number badge beside people in spaces
          // and circles (Matt, 2026-11-19: "add the verfied by number badge as a default feature"). Only yes or no, never
          // the number; by id, and by username for the id that holds it. Up to [badgesAtOnce] of each, so many an hour.
          final now = _now();
          final asked = _badgeAsks[id] ??= [];
          asked.removeWhere((t) => now.difference(t) > const Duration(hours: 1));
          if (asked.length >= badgesAnHour) return err('Too many lookups. Try again in a while.');
          asked.add(now);
          final ids = [for (final x in (said['ids'] is List ? said['ids'] as List : const []).take(badgesAtOnce)) if (x is String && x.length <= 128) x];
          final names = [for (final x in (said['names'] is List ? said['names'] as List : const []).take(badgesAtOnce)) if (x is String && goodName(x)) tidyName(x)];
          tell({
            'dir': 'badges',
            'ids': [for (final x in ids) if (phoneKeyOf(x) != null) x],
            'names': [for (final n in names) if (_names[nameKey(n)] case final found? when found['id'] is String && phoneKeyOf(found['id'] as String) != null) n],
            // The special badges the admin gave (souls are each person's own and not told to others).
            // The one each shows beside their name.
            if (ids.any((x) => showcaseOf(x) != null)) 'show': {for (final x in ids) if (showcaseOf(x) case final String b) x: b},
            if (names.any((n) => _names[nameKey(n)]?['id'] is String && showcaseOf(_names[nameKey(n)]!['id']!) != null))
              'showNames': {
                for (final n in names)
                  if (_names[nameKey(n)]?['id'] case final String holder)
                    if (showcaseOf(holder) case final String b) n: b,
              },
            // Each said only where someone asked of has one.
            if (ids.any((x) => _special[x]?.isNotEmpty ?? false)) 'special': {for (final x in ids) if (_special[x]?.isNotEmpty ?? false) x: _special[x]},
            if (names.any((n) => _special[_names[nameKey(n)]?['id']]?.isNotEmpty ?? false))
              'specialNames': {
                for (final n in names)
                  if (_names[nameKey(n)]?['id'] case final String holder when _special[holder]?.isNotEmpty ?? false) n: _special[holder],
              },
          });
        case 'souls?':
          // This install's own souls and badges.
          tell(_soulsMessage(id));
        case 'souls-seen':
          // The gifts the app has shown: kept no longer.
          final ids = said['ids'];
          final list = _unseen[id];
          if (ids is List && list != null) {
            list.removeWhere((g) => ids.contains(g['g']));
            if (list.isEmpty) _unseen.remove(id);
            _changed();
          }
        case 'showcase':
          // The badge to show beside one's name: one of one's own, or '' for one's highest.
          final b = said['badge'];
          if (b is! String || (b.isNotEmpty && !(_special[id]?.contains(b) ?? false))) return err('That badge isn\'t yours.');
          if (b.isEmpty) {
            _showcase.remove(id);
          } else {
            _showcase[id] = b;
          }
          _changed();
          tell(_soulsMessage(id));
        case 'admin-login':
          // The admin page's sign-in: only from an install holding one of the admin's usernames, a few tries an hour,
          // and good for this connection alone.
          final now = _now();
          final tries = _adminTries[id] ??= [];
          tries.removeWhere((t) => now.difference(t) > const Duration(hours: 1));
          if (tries.length >= adminTriesAnHour) return tell({'dir': 'admin', 'ok': false, 'err': 'Too many tries. Wait an hour.'});
          tries.add(now);
          final user = said['user'], pass = said['pass'];
          if (!_isAdminAccount(id) || user is! String || pass is! String || !adminPassword(user, pass)) {
            _say('${id.substring(0, 6)} admin sign-in refused');
            return tell({'dir': 'admin', 'ok': false, 'err': 'That isn\'t right.'});
          }
          tries.clear();
          (_adminConns[id] ??= {})[tell] = now;
          _say('${id.substring(0, 6)} signed in to the admin page');
          tell({'dir': 'admin', 'ok': true});
        case 'admin-users' || 'admin-give' || 'admin-badge' || 'admin-log':
          // The admin page itself, for a connection signed in to it: everyone known here, the log of what was given,
          // giving or taking souls, and giving or taking a special badge (the person is told at once where connected).
          if (!_adminHere(id, tell)) return tell({'dir': said['dir'], 'ok': false, 'err': 'Sign in to the admin page first.'});
          switch (said['dir']) {
            case 'admin-users':
              tell({'dir': 'admin-users', 'ok': true, 'users': _everyone()});
            case 'admin-log':
              tell({'dir': 'admin-log', 'ok': true, 'grants': _grants.reversed.take(200).toList()});
            case 'admin-give':
              final to = said['to'], n = said['souls'];
              final why = said['why'] is String ? (said['why'] as String).trim() : '';
              if (to is! String || to.isEmpty || n is! int || n == 0 || n.abs() > soulsAtOnce) return tell({'dir': 'admin-give', 'ok': false, 'err': 'Give between 1 and $soulsAtOnce souls, or take as many.'});
              final now = soulsOf(to) + n;
              _souls[to] = now < 0 ? 0 : now;
              final short = why.length > 200 ? why.substring(0, 200) : why;
              _grant(to, {'souls': n, 'why': short});
              final gift = _keepUnseen(to, {'souls': n, 'why': short});
              _changed();
              _here[to]?.call(_soulsMessage(to, got: n, why: short, gift: gift));
              tell({'dir': 'admin-give', 'ok': true, 'to': to, 'n': soulsOf(to)});
            case 'admin-badge':
              final to = said['to'], badge = said['badge'], on = said['on'] == true;
              if (to is! String || to.isEmpty || badge is! String || !specialBadges.contains(badge)) return tell({'dir': 'admin-badge', 'ok': false, 'err': 'No such badge.'});
              final list = _special[to] ??= [];
              if (on && !list.contains(badge)) list.add(badge);
              if (!on) list.remove(badge);
              if (list.isEmpty) _special.remove(to);
              _grant(to, {'badge': badge, 'on': on});
              final gift = on ? _keepUnseen(to, {'badge': badge}) : null;
              _changed();
              _here[to]?.call(_soulsMessage(to, badge: on ? badge : null, gift: gift));
              tell({'dir': 'admin-badge', 'ok': true, 'to': to, 'special': specialOf(to)});
          }
        case 'link':
          // Starts a sign-in: answers the address for the app to open in a browser, good for [stateLife]. The state in
          // it names this install; the verifier is X's PKCE secret, which never leaves this server.
          if (!known || !_signIn.contains(network)) return err('That network is not linked by signing in.');
          if (ways[network] != 'signin') return err('Signing in with that network is not set up on this server yet.');
          final state = hexOf([for (var i = 0; i < 16; i++) _random.nextInt(256)]);
          final verifier = base64Url.encode([for (var i = 0; i < 48; i++) _random.nextInt(256)]).replaceAll('=', '');
          _asked[state] = _Asked(id, network, verifier, _now());
          tell({'dir': 'link', 'p': network, 'url': '${config.publicUrl}/link/$network?s=$state'});
        case 'text':
          // A code, texted to a number by the service (texts.dart). Nothing is linked yet.
          if (network != 'phone') return err('Only a phone number is linked by a text.');
          final number = said['handle'] is String ? tidyNumber(said['handle'] as String) : '';
          final problem = await sendCode(id, number);
          if (problem != null) return err(problem);
          tell({'dir': 'text', 'p': 'phone', 'handle': number});
        case 'code':
          // The code that reached the number, come back: the service says whether it is the one it sent.
          if (network != 'phone') return err('Only a phone number is linked by a text.');
          final number = said['handle'] is String ? tidyNumber(said['handle'] as String) : '';
          final problem = await checkCode(id, number, said['code']);
          if (problem != null) return err(problem);
          _link(id, 'phone', number, number);
        // 'proof' answers the code to put in the account's public profile; 'check' reads the profile and links the
        // account where the code is in it.
        case 'proof':
        case 'check':
          final handle = said['handle'] is String ? tidy(network is String ? network : '', said['handle'] as String) : '';
          if (network == 'phone') return err('A phone number is linked by a code sent to it.');
          if (!known || _signIn.contains(network)) return err('That network is linked by signing in.');
          if (!wellFormed(network, handle)) return err('That does not look like a handle there.');
          final code = codeFor(id, network, handle);
          if (said['dir'] == 'proof') return tell({'dir': 'proof', 'p': network, 'handle': handle, 'code': code});
          if (!_mayFetch(id)) return err('Too many tries this hour. Try again later.');
          final found = await _profile(network, handle);
          if (found == null) return err('That account could not be read. Check the handle.');
          if (!found.text.contains(code)) return err('The code is not in that profile yet. It can take a minute to show.');
          _link(id, network, handle, found.account);
        case 'unlink':
          // Forgets this install's link on one network.
          if (!known) return;
          final gone = _links[id]?.remove(network);
          if (gone != null) {
            if (_links[id]!.isEmpty) _links.remove(id);
            if (_account[gone['a']] == id) _account.remove(gone['a']);
            _changed();
          }
          tell({'dir': 'unlinked', 'p': network});
        case 'listed':
          // The listing switch. Turned on, everyone watching for one of this install's handles is told it joined.
          final on = said['on'] == true;
          if (on && _listed.add(id)) {
            for (final link in (_links[id] ?? const <String, Map<String, String>>{}).entries) {
              if (!_quiet.contains(link.key)) _announce(id, link.value['k']!);
            }
          } else if (!on) {
            _listed.remove(id);
          }
          _changed();
          tell({'dir': 'listed', 'on': on});
        case 'watch':
          // Handle hashes to stop and to start watching for (`remove`, `add`). Those added that a listed install
          // already holds are told straight away, marked `already`.
          final mine = _watch[id] ??= {};
          for (final k in (said['remove'] as List? ?? const []).whereType<String>()) {
            if (mine.remove(k)) {
              _watchers[k]?.remove(id);
              if (_watchers[k]?.isEmpty ?? false) _watchers.remove(k);
            }
          }
          final here = <String>[];
          for (final k in (said['add'] as List? ?? const []).whereType<String>()) {
            if (k.length != 64 || mine.length >= maxWatch && !mine.contains(k)) continue;
            mine.add(k);
            (_watchers[k] ??= {}).add(id);
            if (_listedHolders(k).any((other) => other != id)) here.add(k);
          }
          if (mine.isEmpty) _watch.remove(id);
          _changed();
          tell({'dir': 'watching', 'n': mine.length});
          if (here.isNotEmpty) tell({'dir': 'joined', 'list': here, 'already': true});
        case 'forget':
          // Everything about this install, gone: its links, its listing, its watch list, what waited for it.
          for (final link in (_links.remove(id) ?? const <String, Map<String, String>>{}).values) {
            if (_account[link['a']] == id) _account.remove(link['a']);
          }
          _listed.remove(id);
          for (final k in _watch.remove(id) ?? const <String>{}) {
            _watchers[k]?.remove(id);
            if (_watchers[k]?.isEmpty ?? false) _watchers.remove(k);
          }
          _pending.remove(id);
          _done.remove(id);
          _changed();
          tell({'dir': 'forgotten'});
        case 'follows':
          // Who the linked account follows on a network whose follow lists are public, for the app to watch for.
          final handle = said['handle'] is String ? tidy(network is String ? network : '', said['handle'] as String) : '';
          if (!_proof.contains(network)) return err('Who you follow there cannot be read.');
          // Only of the account this install proved is its own.
          if (_links[id]?[network]?['k'] != keyOf(network, handle)) return err('Link that account first.');
          if (!_mayFetch(id)) return err('Too many tries this hour. Try again later.');
          final found = await _following(network, handle);
          if (found == null) return err('Who that account follows could not be read.');
          tell({'dir': 'follows', 'p': network, 'handles': found});
      }
    } catch (e) {
      err('That did not work. Try again in a while.');
      _say('error in ${said['dir']}: ${e.runtimeType}');
    }
  }

  /// Texts [number] (tidied) a code for [id], within every limit on texts; null once sent, else why not, in words to
  /// show. What linking a number says (`text`), and what signing in to an account whose number is verified says
  /// (accounts.dart), so both are held to the same limits.
  Future<String?> sendCode(String id, String number) async {
    final texts = _texts;
    if (texts == null) return 'Verifying a number by text is not set up on this server yet.';
    if (!wellFormed('phone', number)) return 'That does not look like a phone number. Write it with its country code, like +1 555 010 0199.';
    if (!config.textTo.any(number.startsWith)) return 'Numbers in that country cannot be verified yet.';
    final k = keyOf('phone', number);
    final now = _now();
    sweep();
    if (!_room(_textedBy[id], now, textsAnHour, textsADay)) return 'You have asked for a few codes already. Try again in an hour.';
    if (!_room(_textedTo[k], now, textsAnHour, textsADay)) return 'That number has been sent a few codes already. Try again in an hour.';
    if (!_room(_textedAll, now, config.textsADay, config.textsADay)) return 'No more codes can be sent today. Try again tomorrow.';
    // Counted before it is sent: one that fails is still one asked of the service.
    (_textedBy[id] ??= []).add(now);
    (_textedTo[k] ??= []).add(now);
    _textedAll.add(now);
    switch (await texts.send(number)) {
      case Texted.sent:
        (_codeFor[k] ??= {})[id] = now;
        _say('${id.substring(0, 6)} was texted a code');
        return null;
      case Texted.cannot:
        return 'That number cannot be sent a text. Check it is a mobile number, with its country code.';
      case Texted.tooOften:
        return 'That number has been sent a few codes already. Try again in ten minutes.';
      case Texted.down:
        _say('the text service did not send');
        return 'The code could not be sent just now. Try again in a while.';
    }
  }

  /// Whether [code] is the one texted to [number] for [id] ([sendCode]): null where the service says it is, else why
  /// not. Only an install a code was sent for may try one, a few times an hour.
  Future<String?> checkCode(String id, String number, Object? code) async {
    final texts = _texts;
    if (texts == null) return 'Verifying a number by text is not set up on this server yet.';
    final typed = code is String ? code.replaceAll(RegExp(r'[\s-]'), '') : '';
    if (!wellFormed('phone', number) || !RegExp(r'^[0-9]{4,10}$').hasMatch(typed)) return 'That does not look like the code. It is the digits in the text.';
    final k = keyOf('phone', number);
    final now = _now();
    final asked = _codeFor[k]?[id];
    if (asked == null || now.difference(asked) > codeLife) return 'Ask for a code first. One lasts ten minutes.';
    if (!_room(_tried[id], now, triesAnHour, triesAnHour * 3)) return 'Too many tries. Ask for a new code in an hour.';
    (_tried[id] ??= []).add(now);
    final right = await texts.check(number, typed);
    if (right == null) return 'The code could not be checked just now. Try again.';
    if (!right) return 'That is not the code. Look at the text again, or ask for a new one.';
    _codeFor[k]?.remove(id);
    if (_codeFor[k]?.isEmpty ?? false) _codeFor.remove(k);
    return null;
  }

  /// Whether [id] may look someone up now, and that it has: at most [lookupsAnHour] an hour, so the usernames cannot
  /// be walked through. One count for every kind of lookup an install makes, here or of another relay
  /// (federation.dart).
  bool mayLookUp(String id) {
    final now = _now();
    final list = _lookups[id] ??= [];
    list.removeWhere((t) => now.difference(t) > const Duration(hours: 1));
    if (list.length >= lookupsAnHour) return false;
    list.add(now);
    return true;
  }

  /// Who holds the username [name] here, their name and key: what another relay is told when one of its people asks
  /// (federation.dart, which counts how often that relay asks). Null where nobody does.
  ({String id, String key})? holder(String name) {
    if (!goodName(name)) return null;
    final found = _names[nameKey(name)];
    final id = found?['id'], key = found?['key'];
    return id == null || key == null ? null : (id: id, key: key);
  }

  /// Whether [id] holds a username here: someone who has signed in here (federation.dart keeps packets from other
  /// relays only for such names).
  bool holdsAName(String id) => _nameOf.containsKey(id);

  /// The day [id] first claimed the username it holds (midnight UTC), or null where it holds none.
  DateTime? nameHeldSince(String id) {
    final k = _nameOf[id];
    final at = k == null ? null : _names[k]?['at'];
    return at == null ? null : DateTime.tryParse('${at}T00:00:00Z');
  }

  /// The install that holds [name] as its username, or null (accounts.dart: signing in by username).
  String? holderOf(String name) => goodName(name) ? (_names[nameKey(name)]?['id']) : null;

  /// The listed installs with a link whose handle hashes to [k], a phone number's never among them.
  Iterable<String> _listedHolders(String k) sync* {
    for (final e in _links.entries) {
      if (_listed.contains(e.key) && e.value.entries.any((l) => l.value['k'] == k && !_quiet.contains(l.key))) yield e.key;
    }
  }

  /// The code [id] is to put in [handle]'s profile on [network]: made from a secret only this server has, so it need
  /// not be remembered, and nobody else's code is the same.
  String codeFor(String id, String network, String handle) =>
      'ghost-${hexOf(hmacSha256(utf8.encode(_secret), utf8.encode('$id|$network|$handle'))).substring(0, 10)}';

  /// [id] has proved [handle] on [network] is theirs. [account] is the network's own number for it, which stays
  /// the same when a handle is renamed and is what makes one account one install's: linked again from another
  /// install, the first one's link goes.
  /// [about]: what the network said of the account as it signed in (its name, its picture's address), handed to the
  /// install there and then so it can fill in a profile (Matt, 2026-11-19: "sign up with discord ... loads your picture
  /// and username"), and never kept: one told later, by [_done], is told without it.
  void _link(String id, String network, String handle, String account, {Map<String, String> about = const {}}) {
    final k = keyOf(network, handle);
    final a = hexOf(sha256(utf8.encode('ghost-account v1|$network|$account')));
    final before = _account[a];
    if (before != null && before != id) {
      _links[before]?.remove(network);
      if (_links[before]?.isEmpty ?? false) _links.remove(before);
    }
    final old = _links[id]?[network];
    if (old != null && old['a'] != a && _account[old['a']] == id) _account.remove(old['a']);
    (_links[id] ??= {})[network] = {'k': k, 'a': a, 'at': _now().toUtc().toIso8601String().substring(0, 10)};
    _account[a] = id;
    _changed();
    final told = {'p': network, 'handle': handle, 'k': k};
    final tell = _here[id];
    if (tell != null) {
      tell({'dir': 'linked', ...told, if (about.isNotEmpty) 'about': about});
    } else {
      (_done[id] ??= []).add(told);
    }
    _say('${id.substring(0, 6)} linked $network');
    if (_listed.contains(id) && old?['k'] != k && !_quiet.contains(network)) _announce(id, k);
  }

  /// Tells everyone watching for [k] that it is here now.
  void _announce(String id, String k) {
    for (final watcher in _watchers[k] ?? const <String>{}) {
      if (watcher == id) continue;
      final tell = _here[watcher];
      if (tell != null) {
        tell({'dir': 'joined', 'list': [k]});
      } else {
        final box = _pending[watcher] ??= [];
        if (!box.contains(k) && box.length < maxPending) box.add(k);
      }
    }
    _changed();
  }

  // --- reading a public profile: Bluesky, Mastodon, GitHub -------------------------------------------------------------

  /// What GitHub's API is asked with: it refuses a request with no User-Agent, and allows more with a token.
  Map<String, String> get _githubHeaders => {
        'User-Agent': 'ghost-messaging-relay',
        'Accept': 'application/vnd.github+json',
        if (config.githubToken.isNotEmpty) 'Authorization': 'Bearer ${config.githubToken}',
      };

  /// The words of [handle]'s public profile on [network], and the network's own number for the account.
  Future<({String text, String account})?> _profile(String network, String handle) async {
    switch (network) {
      case 'bluesky':
        final r = await _fetch('GET', Uri.https('public.api.bsky.app', '/xrpc/app.bsky.actor.getProfile', {'actor': handle}));
        if (r.status != 200) return null;
        final m = jsonDecode(r.body) as Map;
        return (text: '${m['description'] ?? ''} ${m['displayName'] ?? ''}', account: '${m['did']}');
      case 'mastodon':
        final at = handle.indexOf('@');
        final r = await _fetch('GET', Uri.https(handle.substring(at + 1), '/api/v1/accounts/lookup', {'acct': handle.substring(0, at)}), outside: true);
        if (r.status != 200) return null;
        final m = jsonDecode(r.body) as Map;
        final fields = [for (final f in (m['fields'] as List? ?? const [])) '${(f as Map)['name']} ${f['value']}'].join(' ');
        return (text: '${m['note'] ?? ''} $fields ${m['display_name'] ?? ''}', account: '${handle.substring(at + 1)}/${m['id']}');
      case 'github':
        final r = await _fetch('GET', Uri.https('api.github.com', '/users/$handle'), headers: _githubHeaders);
        if (r.status != 200) return null;
        final m = jsonDecode(r.body) as Map;
        return (text: '${m['bio'] ?? ''} ${m['blog'] ?? ''} ${m['company'] ?? ''}', account: '${m['id']}');
    }
    return null;
  }

  /// The handles [handle] follows on [network], at most [maxFollows].
  Future<List<String>?> _following(String network, String handle) async {
    final out = <String>[];
    switch (network) {
      case 'bluesky':
        String? cursor;
        for (var page = 0; page < 50 && out.length < maxFollows; page++) {
          final r = await _fetch('GET', Uri.https('public.api.bsky.app', '/xrpc/app.bsky.graph.getFollows', {'actor': handle, 'limit': '100', 'cursor': ?cursor}));
          if (r.status != 200) return page == 0 ? null : out;
          final m = jsonDecode(r.body) as Map;
          out.addAll([for (final f in (m['follows'] as List? ?? const [])) '${(f as Map)['handle']}']);
          cursor = m['cursor'] as String?;
          if (cursor == null) break;
        }
      case 'mastodon':
        final at = handle.indexOf('@');
        final host = handle.substring(at + 1);
        final who = await _fetch('GET', Uri.https(host, '/api/v1/accounts/lookup', {'acct': handle.substring(0, at)}), outside: true);
        if (who.status != 200) return null;
        final id = '${(jsonDecode(who.body) as Map)['id']}';
        if (!RegExp(r'^[A-Za-z0-9]+$').hasMatch(id)) return null;
        String? maxId;
        for (var page = 0; page < 60 && out.length < maxFollows; page++) {
          final r = await _fetch('GET', Uri.https(host, '/api/v1/accounts/$id/following', {'limit': '80', 'max_id': ?maxId}), outside: true);
          if (r.status != 200) return page == 0 ? null : out;
          final list = jsonDecode(r.body) as List;
          if (list.isEmpty) break;
          out.addAll([for (final f in list) '${(f as Map)['acct']}'.contains('@') ? '${f['acct']}' : '${f['acct']}@$host']);
          // The next page is named in the Link header: <…max_id=123>; rel="next".
          maxId = RegExp(r'max_id=([A-Za-z0-9]+)[^>]*>;\s*rel="next"').firstMatch(r.headers['link'] ?? '')?.group(1);
          if (maxId == null) break;
        }
      case 'github':
        for (var page = 1; page <= 50 && out.length < maxFollows; page++) {
          final r = await _fetch('GET', Uri.https('api.github.com', '/users/$handle/following', {'per_page': '100', 'page': '$page'}), headers: _githubHeaders);
          if (r.status != 200) return page == 1 ? null : out;
          final list = jsonDecode(r.body) as List;
          out.addAll([for (final f in list) '${(f as Map)['login']}']);
          if (list.length < 100) break;
        }
      default:
        return null;
    }
    return [for (final h in out.take(maxFollows)) tidy(network, h)].where((h) => wellFormed(network, h)).toSet().toList();
  }

  // --- signing in: Discord, X, Telegram (a browser's requests, under /link/) -------------------------------------------

  /// Where [network] sends the browser back to once the person has signed in: the address registered with it.
  String _redirect(String network) => '${config.publicUrl}/link/$network/callback';

  /// The one small page a browser is shown here. [title] is escaped; [words] is HTML and the caller escapes what it
  /// puts in it.
  static String _page(String title, String words) => '''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Uplink</title>
<style>
  :root { color-scheme: light dark; --bg: #fdfdfd; --ink: #0e0e10; --ink2: #55565c; }
  @media (prefers-color-scheme: dark) { :root { --bg: #000; --ink: #f2f2f3; --ink2: #a3a4ab; } }
  body { margin: 0; min-height: 100vh; display: grid; place-items: center; font: 17px/1.5 Inter, system-ui, sans-serif; background: var(--bg); color: var(--ink); }
  main { max-width: 26rem; padding: 2rem 1.5rem; text-align: center; }
  h1 { font-size: 1.6rem; letter-spacing: -0.02em; margin: 0 0 0.5rem; }
  p { color: var(--ink2); margin: 0 0 1.25rem; }
</style></head>
<body><main><h1>${const HtmlEscape().convert(title)}</h1>$words</main></body></html>
''';

  /// Answers a browser with [_page], never cached. [_sorry] is the page for a sign-in that failed, [_thanks] for one
  /// that linked.
  Future<void> _html(HttpRequest request, int status, String title, String words) async {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.html
      ..headers.set('Cache-Control', 'no-store')
      ..headers.set('Referrer-Policy', 'no-referrer')
      ..headers.set('X-Content-Type-Options', 'nosniff')
      ..write(_page(title, words));
    await request.response.close();
  }

  Future<void> _sorry(HttpRequest request, String why) => _html(request, HttpStatus.badRequest, 'That didn\'t work', '<p>${const HtmlEscape().convert(why)}</p><p>Go back to Uplink and try again.</p>');

  Future<void> _thanks(HttpRequest request, String network, String handle) => _html(request, HttpStatus.ok, 'Linked',
      '<p>${const HtmlEscape().convert('@$handle')} on ${const HtmlEscape().convert(nameOf(network))} is linked to your Uplink.</p><p>You can close this page and go back to the app.</p>');

  /// A network's name as people write it.
  static String nameOf(String network) => switch (network) {
        'x' => 'X',
        'github' => 'GitHub',
        _ => network[0].toUpperCase() + network.substring(1),
      };

  /// A browser's request under `/link/`: `/link/<network>?s=<state>` starts a sign-in, `/link/<network>/callback`
  /// ends one. Returns false where the address is not one of these.
  Future<bool> http(HttpRequest request) async {
    final parts = request.uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (parts.length < 2 || parts[0] != 'link' || !_signIn.contains(parts[1])) return false;
    final network = parts[1];
    final q = request.uri.queryParameters;
    sweep();
    try {
      if (parts.length == 2) {
        final asked = _asked[q['s']];
        if (asked == null || asked.network != network || ways[network] != 'signin') {
          await _sorry(request, 'This link is no longer good. They last ten minutes.');
          return true;
        }
        if (network == 'telegram') {
          // Telegram's own button, which sends the person back to the callback with who they are, signed.
          await _html(request, HttpStatus.ok, 'Link Telegram',
              '<p>Sign in with Telegram to show this account is yours.</p><script async src="https://telegram.org/js/telegram-widget.js?22" data-telegram-login="${const HtmlEscape().convert(config.telegramBot)}" data-size="large" data-auth-url="${const HtmlEscape().convert('${_redirect(network)}?state=${q['s']}')}"></script>');
          return true;
        }
        final to = network == 'discord'
            ? Uri.https('discord.com', '/oauth2/authorize', {'response_type': 'code', 'client_id': config.discordId, 'scope': 'identify', 'state': q['s'], 'redirect_uri': _redirect(network), 'prompt': 'consent'})
            : Uri.https('x.com', '/i/oauth2/authorize', {
                'response_type': 'code',
                'client_id': config.xId,
                'redirect_uri': _redirect(network),
                'scope': 'users.read tweet.read',
                'state': q['s'],
                'code_challenge': base64Url.encode(sha256(ascii.encode(asked.verifier))).replaceAll('=', ''),
                'code_challenge_method': 'S256',
              });
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set('Location', to.toString())
          ..headers.set('Cache-Control', 'no-store');
        await request.response.close();
        return true;
      }
      if (parts.length != 3 || parts[2] != 'callback') return false;
      // A state is good once: taken as it is looked at.
      final asked = _asked.remove(q['state']);
      if (asked == null || asked.network != network) {
        await _sorry(request, 'This sign-in was not started from the app, or took longer than ten minutes.');
        return true;
      }
      final ({String account, String handle, Map<String, String> about})? who;
      if (network == 'telegram') {
        who = _telegram(q);
      } else {
        final code = q['code'];
        if (code == null || code.isEmpty) {
          await _sorry(request, 'The sign-in was cancelled.');
          return true;
        }
        who = network == 'discord' ? await _discord(code) : await _x(code, asked.verifier);
      }
      if (who == null) {
        await _sorry(request, 'That account could not be confirmed.');
        return true;
      }
      if (who.handle.isEmpty) {
        await _sorry(request, 'That account has no username. Set one in ${nameOf(network)} first, then link it again.');
        return true;
      }
      final handle = tidy(network, who.handle);
      _link(asked.id, network, handle, who.account, about: who.about);
      await _thanks(request, network, handle);
    } catch (e) {
      _say('sign-in error on $network: ${e.runtimeType}');
      await _sorry(request, 'Something went wrong on the way.');
    }
    return true;
  }

  /// [fields] as a form's body (application/x-www-form-urlencoded).
  static String _form(Map<String, String> fields) => fields.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&');

  /// Who signed in at Discord: the callback's [code] is swapped for a token, the token used once to ask who it is,
  /// and then dropped. Null where Discord doesn't confirm it.
  Future<({String account, String handle, Map<String, String> about})?> _discord(String code) async {
    final token = await _fetch('POST', Uri.https('discord.com', '/api/oauth2/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded', 'Authorization': 'Basic ${base64Encode(utf8.encode('${config.discordId}:${config.discordSecret}'))}'},
        body: _form({'grant_type': 'authorization_code', 'code': code, 'redirect_uri': _redirect('discord')}));
    if (token.status != 200) return null;
    final access = (jsonDecode(token.body) as Map)['access_token'];
    if (access is! String) return null;
    final me = await _fetch('GET', Uri.https('discord.com', '/api/users/@me'), headers: {'Authorization': 'Bearer $access'});
    if (me.status != 200) return null;
    final m = jsonDecode(me.body) as Map;
    final avatar = m['avatar'];
    return (
      account: '${m['id']}',
      handle: '${m['username'] ?? ''}',
      about: {
        if (m['global_name'] is String) 'name': m['global_name'] as String,
        if (avatar is String && avatar.isNotEmpty) 'picture': 'https://cdn.discordapp.com/avatars/${m['id']}/$avatar.png?size=256',
      },
    );
  }

  /// Who signed in at X, the same way, with the [verifier] whose hash went out when the sign-in started (PKCE).
  Future<({String account, String handle, Map<String, String> about})?> _x(String code, String verifier) async {
    final token = await _fetch('POST', Uri.https('api.x.com', '/2/oauth2/token'),
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          // A confidential client signs in with its secret; a public one names itself in the form alone.
          if (config.xSecret.isNotEmpty) 'Authorization': 'Basic ${base64Encode(utf8.encode('${config.xId}:${config.xSecret}'))}',
        },
        body: _form({'grant_type': 'authorization_code', 'code': code, 'redirect_uri': _redirect('x'), 'code_verifier': verifier, 'client_id': config.xId}));
    if (token.status != 200) return null;
    final access = (jsonDecode(token.body) as Map)['access_token'];
    if (access is! String) return null;
    final me = await _fetch('GET', Uri.https('api.x.com', '/2/users/me'), headers: {'Authorization': 'Bearer $access'});
    if (me.status != 200) return null;
    final m = (jsonDecode(me.body) as Map)['data'] as Map?;
    if (m == null) return null;
    return (account: '${m['id']}', handle: '${m['username'] ?? ''}', about: {if (m['name'] is String) 'name': m['name'] as String});
  }

  /// Who Telegram's button says signed in: every field it sent, in order, signed with a key made from our bot's
  /// token (core.telegram.org/widgets/login). Good for a day.
  ({String account, String handle, Map<String, String> about})? _telegram(Map<String, String> q) {
    final hash = q['hash'];
    final when = int.tryParse(q['auth_date'] ?? '');
    if (hash == null || when == null || q['id'] == null) return null;
    const theirs = {'id', 'first_name', 'last_name', 'username', 'photo_url', 'auth_date'};
    final lines = [for (final k in q.keys.where(theirs.contains).toList()..sort()) '$k=${q[k]}'].join('\n');
    final want = hexOf(hmacSha256(sha256(utf8.encode(config.telegramToken)), utf8.encode(lines)));
    if (!_same(want, hash.toLowerCase())) return null;
    if (_now().toUtc().millisecondsSinceEpoch ~/ 1000 - when > 86400) return null;
    final name = [q['first_name'], q['last_name']].whereType<String>().where((x) => x.trim().isNotEmpty).join(' ').trim();
    final photo = q['photo_url'] ?? '';
    return (account: q['id']!, handle: q['username'] ?? '', about: {if (name.isNotEmpty) 'name': name, if (photo.startsWith('https://')) 'picture': photo});
  }

  /// Compared without stopping at the first difference.
  static bool _same(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}

/// A sign-in started in the app and not yet finished in the browser: which install asked, for which network, X's
/// PKCE verifier, and when.
class _Asked {
  _Asked(this.id, this.network, this.verifier, this.at);
  final String id;
  final String network;
  final String verifier;
  final DateTime at;
}

/// What the networks' sign-ins need, from the server's environment (bin/relay.dart). A network whose values are
/// empty is "off": the app says its sign-in is not set up, and nothing else changes.
class HandlesConfig {
  const HandlesConfig({
    this.publicUrl = 'https://ghost-sms.com',
    this.discordId = '',
    this.discordSecret = '',
    this.xId = '',
    this.xSecret = '',
    this.telegramBot = '',
    this.telegramToken = '',
    this.githubToken = '',
    this.twilioSid = '',
    this.twilioToken = '',
    this.twilioVerify = '',
    this.textTo = const ['+1'],
    this.textsADay = 200,
    this.adminUser = '',
    this.adminHash = '',
    this.adminNames = const ['matt'],
  });

  factory HandlesConfig.fromEnvironment(Map<String, String> env) => HandlesConfig(
        // Still ghost-sms.com after the move to gogho.st (2026-11-15): the sign-in pages' callback addresses are the
        // ones Discord, X and Telegram were given. Once gogho.st's are added there, GHOST_PUBLIC_URL moves it.
        publicUrl: (env['GHOST_PUBLIC_URL'] ?? 'https://ghost-sms.com').replaceAll(RegExp(r'/+$'), ''),
        discordId: env['GHOST_DISCORD_ID'] ?? '',
        discordSecret: env['GHOST_DISCORD_SECRET'] ?? '',
        xId: env['GHOST_X_ID'] ?? '',
        xSecret: env['GHOST_X_SECRET'] ?? '',
        telegramBot: env['GHOST_TELEGRAM_BOT'] ?? '',
        telegramToken: env['GHOST_TELEGRAM_TOKEN'] ?? '',
        githubToken: env['GHOST_GITHUB_TOKEN'] ?? '',
        twilioSid: env['GHOST_TWILIO_SID'] ?? '',
        twilioToken: env['GHOST_TWILIO_TOKEN'] ?? '',
        twilioVerify: env['GHOST_TWILIO_VERIFY'] ?? '',
        textTo: [
          for (final p in (env['GHOST_TEXT_TO'] ?? '+1').split(','))
            if (RegExp(r'^\+[0-9]{1,6}$').hasMatch(p.trim())) p.trim(),
        ],
        textsADay: int.tryParse(env['GHOST_TEXTS_A_DAY'] ?? '') ?? 200,
        adminUser: env['GHOST_ADMIN_USER'] ?? '',
        adminHash: env['GHOST_ADMIN_HASH'] ?? '',
        adminNames: [for (final n in (env['GHOST_ADMIN_NAMES'] ?? 'matt').split(',')) if (n.trim().isNotEmpty) n.trim()],
      );

  /// The admin page's sign-in (Matt, 2026-11-19: "a simple admin page for me to login to ... with a pre generated
  /// username and password"): the username, and the password as `salt:hash` (Handles.adminHashOf). Either empty and
  /// nobody can sign in. Only an install holding one of [adminNames] may try ("only my matt account").
  final String adminUser;
  final String adminHash;
  final List<String> adminNames;

  /// Where this server is reached from outside: what a sign-in comes back to.
  final String publicUrl;

  /// The OAuth client's id and secret at Discord and at X. X's secret may be empty (a public client).
  final String discordId;
  final String discordSecret;
  final String xId;
  final String xSecret;

  /// The bot's username, without "@", and its token.
  final String telegramBot;
  final String telegramToken;

  /// Optional: GitHub lets a server with a token read far more often than one without.
  final String githubToken;

  /// What texts a phone number its code (texts.dart, Twilio Verify): the account's SID and auth token, or an API
  /// key's SID and secret, and the Verify service's SID. With any of the three empty a number cannot be linked.
  final String twilioSid;
  final String twilioToken;
  final String twilioVerify;

  /// The numbers that may be texted, by how they start: North America unless said otherwise. Texts to some
  /// countries cost many times more, and are what people who make money from texts being sent ask for.
  final List<String> textTo;

  /// The most texts sent in a day, to everyone together: what a mistake or an attack can cost.
  final int textsADay;

  /// Whether texting a code is set up.
  bool get texts => twilioSid.isNotEmpty && twilioToken.isNotEmpty && twilioVerify.isNotEmpty;
}

/// What another server answered: its status (0 where it could not be asked at all), its body as text, and the few
/// headers kept (`link`, for a next page).
class Fetched {
  const Fetched(this.status, this.body, [this.headers = const {}]);
  final int status;
  final String body;
  final Map<String, String> headers;
}

/// One request to another server. [outside] marks an address a person typed (a Mastodon server): it is refused
/// unless it resolves to a public address, so this server cannot be pointed at its own network.
typedef Fetch = Future<Fetched> Function(String method, Uri url, {Map<String, String> headers, String? body, bool outside});

/// Whether [a] is an address no outside server has: this machine, a private or carrier network, link-local, multicast.
bool _private(InternetAddress a) {
  if (a.isLoopback || a.isLinkLocal || a.isMulticast) return true;
  final b = a.rawAddress;
  if (a.type == InternetAddressType.IPv4) {
    return b[0] == 10 || b[0] == 127 || b[0] == 0 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254) || (b[0] == 100 && b[1] >= 64 && b[1] <= 127) || b[0] >= 224;
  }
  // Unique local (fc00::/7), and IPv4 addresses written as IPv6.
  if ((b[0] & 0xfe) == 0xfc) return true;
  if (b.sublist(0, 10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff) return _private(InternetAddress.fromRawAddress(Uint8List.fromList(b.sublist(12))));
  return false;
}

/// Over https only, following no redirect, fifteen seconds and one megabyte at most.
Future<Fetched> defaultFetch(String method, Uri url, {Map<String, String> headers = const {}, String? body, bool outside = false}) async {
  if (url.scheme != 'https') return const Fetched(0, '');
  InternetAddress? at;
  if (outside) {
    try {
      final found = await InternetAddress.lookup(url.host).timeout(const Duration(seconds: 5));
      if (found.isEmpty || found.any(_private)) return const Fetched(0, '');
      at = found.first;
    } catch (_) {
      return const Fetched(0, '');
    }
  }
  return fetchAt(method, url, at, headers: headers, body: body);
}

/// [defaultFetch]'s request itself. With [at], the connection is made to that address and no other, the name in
/// [url] used only for the certificate and the Host header: the address that was checked is the one spoken to, so a
/// name answered with a public address for the check and a private one a moment later (DNS rebinding) reaches
/// nothing. No redirect is followed, so there is no second name to check. [context]: the certificates trusted, for a test.
Future<Fetched> fetchAt(String method, Uri url, InternetAddress? at, {Map<String, String> headers = const {}, String? body, SecurityContext? context}) async {
  final client = HttpClient(context: context)..connectionTimeout = const Duration(seconds: 8);
  if (at != null) {
    client.connectionFactory = (uri, _, _) async {
      final dial = await Socket.startConnect(at, uri.port);
      return ConnectionTask.fromSocket(dial.socket.then((s) => SecureSocket.secure(s, host: uri.host, context: context)), dial.cancel);
    };
  }
  try {
    final request = await client.openUrl(method, url).timeout(const Duration(seconds: 10));
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    if (body != null) request.add(utf8.encode(body));
    final response = await request.close().timeout(const Duration(seconds: 15));
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 15))) {
      bytes.addAll(chunk);
      if (bytes.length > 1 << 20) break;
    }
    return Fetched(response.statusCode, utf8.decode(bytes, allowMalformed: true), {'link': response.headers.value('link') ?? ''});
  } catch (_) {
    return const Fetched(0, '');
  } finally {
    client.close(force: true);
  }
}

/// HMAC-SHA256 (RFC 2104), with this folder's own SHA-256.
Uint8List hmacSha256(List<int> key, List<int> message) {
  var k = key.length > 64 ? sha256(key).toList() : key.toList();
  k = [...k, ...List.filled(64 - k.length, 0)];
  final inner = sha256([for (final b in k) b ^ 0x36, ...message]);
  return sha256([for (final b in k) b ^ 0x5c, ...inner]);
}
