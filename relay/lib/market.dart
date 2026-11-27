import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'files.dart';
import 'files_roster.dart';
import 'market_pack.dart';
import 'market_store.dart';
import 'p256.dart';
import 'sha256.dart';

/// The Marketplace's limits, from the environment where they are set (`GHOST_MARKET_*`, tool/deploy-relay.mjs's KNOWN
/// lists the same names, [names]). Each has a default where it is not set.
class MarketConfig {
  const MarketConfig({
    this.on = true,
    this.maxPackage = 262144,
    this.maxShot = 1048576,
    this.maxShots = 4,
    this.maxBody = 6291456,
    this.total = 1073741824,
    this.submissionsADay = 5,
    this.submissionsPerAddress = 3,
    this.openPerDeveloper = 3,
    this.openPerAddress = 3,
    this.openTotal = 200,
    this.openUnverified = 20,
    this.nameAgeDays = 7,
    this.pluginsPerDeveloper = 20,
    this.maxPlugins = 1000,
    this.bytesPerDeveloper = 25165824,
    this.signedAnHour = 300,
    this.signedPerAddress = 60,
    this.verifyASecond = 20,
    this.bodiesInFlight = 3,
    this.readsPerMinute = 240,
    this.reportsADay = 500,
    this.needVerified = false,
    this.reviewKeys = const [],
  });

  /// Off, every route but `GET /market` (which says `open: false`) answers 503 `off`.
  final bool on;

  /// The largest package, screenshot and request body, in bytes, and how many screenshots a submission may have. A body
  /// is never more than Caddy lets through (tool/deploy-site.mjs's request_body, 10 MiB: 10,485,760 bytes).
  final int maxPackage, maxShot, maxShots, maxBody;

  /// What the Marketplace may keep on disk in all, packages and screenshots, in bytes; and per developer.
  final int total, bytesPerDeveloper;

  /// Submissions a day by one someone (the number or account a key proved, else the key) and from one address.
  final int submissionsADay, submissionsPerAddress;

  /// Submissions waiting for review at once: one developer's, one address's, everyone's, and of those everyone's, how
  /// many may be from developers with no verified number or linked account (only while [needVerified] is off).
  final int openPerDeveloper, openPerAddress, openTotal, openUnverified;

  /// How many days a username must have been held before it can submit: a username and a key cost nothing.
  final int nameAgeDays;

  /// Plugin ids one developer may hold (with an approved version or one waiting), and ids with an approved version in all.
  final int pluginsPerDeveloper, maxPlugins;

  /// Signed requests one key may make an hour (counted once its signature checks out, so nobody spends someone else's),
  /// and one address a minute (counted before any check, so a stranger's flood costs the relay no signature checks).
  final int signedAnHour, signedPerAddress;

  /// Signature checks in all, a second: each is a P-256 verification on the hub's one core.
  final int verifyASecond;

  /// Request bodies over 64 KiB being read at once (and that many times [maxBody] in bytes).
  final int bodiesInFlight;

  /// Public reads (the catalog, packages, screenshots) by one address a minute.
  final int readsPerMinute;

  /// Reports a day in all from senders with no verified number or linked account.
  final int reportsADay;

  /// Only developers with a verified number or a linked account may submit (Matt's to switch on when it opens).
  final bool needVerified;

  /// The review keys (base64 of each 33-byte public key) whose approvals the store takes; empty takes the signed-in
  /// admin's own key alone. The apps trust only the keys they ship with, whatever this says.
  final List<String> reviewKeys;

  /// Every limit from its name where it reads as its kind says: a whole number (above nothing where nothing would make
  /// no sense), held to its most where it has one; 0 or 1 for a switch; for the review keys, a comma list of keys. A
  /// value that doesn't read keeps the default.
  factory MarketConfig.fromEnvironment(Map<String, String> env) {
    const d = MarketConfig();
    int read(String name, int fallback, {int least = 1, int? most}) {
      final raw = env[name]?.trim() ?? '';
      final v = RegExp(r'^[0-9]{1,15}$').hasMatch(raw) ? int.tryParse(raw) : null;
      if (v == null || v < least) return fallback;
      return most != null && v > most ? most : v;
    }

    bool flag(String name, bool fallback) => switch (env[name]?.trim()) {
          '0' => false,
          '1' => true,
          _ => fallback,
        };
    final openTotal = read('GHOST_MARKET_OPEN_TOTAL', d.openTotal);
    return MarketConfig(
      on: flag('GHOST_MARKET_ON', d.on),
      maxPackage: read('GHOST_MARKET_MAX_PACKAGE', d.maxPackage, most: 1048576),
      maxShot: read('GHOST_MARKET_MAX_SHOT', d.maxShot, most: 2097152),
      maxShots: read('GHOST_MARKET_MAX_SHOTS', d.maxShots, most: 8),
      // No bigger than Caddy lets through (tool/deploy-site.mjs's request_body).
      maxBody: read('GHOST_MARKET_MAX_BODY', d.maxBody, most: 10485760),
      total: read('GHOST_MARKET_TOTAL', d.total),
      submissionsADay: read('GHOST_MARKET_SUBMISSIONS_A_DAY', d.submissionsADay),
      submissionsPerAddress: read('GHOST_MARKET_SUBMISSIONS_PER_ADDRESS', d.submissionsPerAddress),
      openPerDeveloper: read('GHOST_MARKET_OPEN_PER_DEVELOPER', d.openPerDeveloper),
      openPerAddress: read('GHOST_MARKET_OPEN_PER_ADDRESS', d.openPerAddress),
      openTotal: openTotal,
      openUnverified: read('GHOST_MARKET_OPEN_UNVERIFIED', min(d.openUnverified, openTotal), least: 0, most: openTotal),
      nameAgeDays: read('GHOST_MARKET_NAME_AGE_DAYS', d.nameAgeDays, least: 0, most: 365),
      pluginsPerDeveloper: read('GHOST_MARKET_PLUGINS_PER_DEVELOPER', d.pluginsPerDeveloper),
      maxPlugins: read('GHOST_MARKET_MAX_PLUGINS', d.maxPlugins),
      bytesPerDeveloper: read('GHOST_MARKET_BYTES_PER_DEVELOPER', d.bytesPerDeveloper),
      signedAnHour: read('GHOST_MARKET_SIGNED_AN_HOUR', d.signedAnHour),
      signedPerAddress: read('GHOST_MARKET_SIGNED_PER_ADDRESS', d.signedPerAddress),
      verifyASecond: read('GHOST_MARKET_VERIFY_A_SECOND', d.verifyASecond, most: 1000),
      bodiesInFlight: read('GHOST_MARKET_BODIES_IN_FLIGHT', d.bodiesInFlight, most: 20),
      readsPerMinute: read('GHOST_MARKET_READS_PER_MINUTE', d.readsPerMinute),
      reportsADay: read('GHOST_MARKET_REPORTS_A_DAY', d.reportsADay),
      needVerified: flag('GHOST_MARKET_NEED_VERIFIED', d.needVerified),
      reviewKeys: _keysOf(env['GHOST_MARKET_REVIEW_KEYS']) ?? d.reviewKeys,
    );
  }

  /// A comma list of review keys, each base64 of a 33-byte compressed key; null where any isn't one.
  static List<String>? _keysOf(String? raw) {
    final text = raw?.trim() ?? '';
    if (text.isEmpty) return null;
    final keys = [for (final k in text.split(',')) k.trim()];
    for (final k in keys) {
      final bytes = k.length == 44 ? strictBase64(k) : null;
      if (bytes == null || bytes.length != 33 || (bytes[0] != 2 && bytes[0] != 3)) return null;
    }
    return keys;
  }

  /// The names [MarketConfig.fromEnvironment] reads.
  static const names = [
    'GHOST_MARKET_ON',
    'GHOST_MARKET_MAX_PACKAGE',
    'GHOST_MARKET_MAX_SHOT',
    'GHOST_MARKET_MAX_SHOTS',
    'GHOST_MARKET_MAX_BODY',
    'GHOST_MARKET_TOTAL',
    'GHOST_MARKET_SUBMISSIONS_A_DAY',
    'GHOST_MARKET_SUBMISSIONS_PER_ADDRESS',
    'GHOST_MARKET_OPEN_PER_DEVELOPER',
    'GHOST_MARKET_OPEN_PER_ADDRESS',
    'GHOST_MARKET_OPEN_TOTAL',
    'GHOST_MARKET_OPEN_UNVERIFIED',
    'GHOST_MARKET_NAME_AGE_DAYS',
    'GHOST_MARKET_PLUGINS_PER_DEVELOPER',
    'GHOST_MARKET_MAX_PLUGINS',
    'GHOST_MARKET_BYTES_PER_DEVELOPER',
    'GHOST_MARKET_SIGNED_AN_HOUR',
    'GHOST_MARKET_SIGNED_PER_ADDRESS',
    'GHOST_MARKET_VERIFY_A_SECOND',
    'GHOST_MARKET_BODIES_IN_FLIGHT',
    'GHOST_MARKET_READS_PER_MINUTE',
    'GHOST_MARKET_REPORTS_A_DAY',
    'GHOST_MARKET_NEED_VERIFIED',
    'GHOST_MARKET_REVIEW_KEYS',
  ];
}

/// The Marketplace: the store of plugins from other developers and its review queue (Matt, 2026-11-20: "I would like
/// users to be able to develop and submit their own plugins to our plugin marketplace and I'd like to be able to verify
/// them for the store through a review process ... Add a submission area with a form to accept an icon, description,
/// plugin tags, etc"), plain HTTP under `/market` (docs/marketplace.md; README.md lists the routes).
///
/// - **What it keeps** (market_store.dart): each submitted package and its screenshots by their SHA-256, each
///   submission's state and notes, each plugin's listing and approved versions, developers (by hub id) and whether they
///   are blocked, reports, and the withdrawals and retirements review signed. Nothing it holds is secret beyond what the
///   admin session already guards: a package and its screenshots are public once listed, and until then only their
///   developer and review are shown them.
/// - **Who may do what.** Anyone reads the catalog, the withdrawals, an approved package and a listed plugin's
///   screenshots. Everything else is signed with the asker's hub key, as Files' writes are ([signedWords], with the
///   body's hash and length said up front); a developer submits only under a username their key holds, a week after
///   claiming it. Review is whoever signed in to the admin page over the hub lately ([adminSignedIn]), so no password
///   travels over HTTP; approving, listing, withdrawing and blocking ask for a sign-in within the last 30 minutes.
/// - **The relay is never trusted with a plugin.** An approval is the reviewer's own signature over the plugin's id,
///   version and package's SHA-256 ([approvalWords]), which every app checks with the review keys it ships with, at
///   install and every load: a relay that is wrong or broken into can withhold plugins, never make one reviewed. The
///   catalog carries no words or pictures, only what an approval covers; the app draws everything from the package.
/// - **What a stranger costs it.** A signed request is checked cheapest first, and refused unread, before a byte of its
///   body is read; signature checks are budgeted per address and in all; few large bodies are read at once; the catalog
///   and the withdrawals are answered from memory. Submissions are taken one at a time.
class Market {
  Market({required this.dir, this.config = const MarketConfig(), required this.ownsName, required this.whoOf, required this.adminSignedIn, required this.claimedOn, this.usernameOf, bool Function(List<int> key, List<int> message, List<int> signature)? verify, DateTime Function()? now, this.verbose = false, Duration? bodyPause, Duration? bodyWhole, Duration? bodyRateEvery, Random? random})
      : _verify = verify ?? P256.verify,
        _now = now ?? DateTime.now,
        _bodyPause = bodyPause ?? const Duration(seconds: 30),
        _bodyWhole = bodyWhole ?? const Duration(seconds: 60),
        _bodyRateEvery = bodyRateEvery ?? const Duration(seconds: 10),
        _random = random ?? Random.secure(),
        _store = MarketStore(dir, now: now);

  /// `<data>/market`.
  final Directory dir;
  final MarketConfig config;

  /// Whether the install [id] holds the username [name] (Handles.ownsName).
  final bool Function(String id, String name) ownsName;

  /// The number or account [id] proved, or null (Handles.whoOf): what limits are counted by beyond a key.
  final String? Function(String id) whoOf;

  /// Whether some connection of [id] signed in to the admin page less than [within] ago (Handles.adminSignedIn).
  final bool Function(String id, {Duration within}) adminSignedIn;

  /// When [id]'s username was claimed (Handles.claimedOn).
  final DateTime? Function(String id) claimedOn;

  /// The username [id] holds, for the admin's view (Handles.usernameOf).
  final String? Function(String id)? usernameOf;
  final bool verbose;
  final bool Function(List<int> key, List<int> message, List<int> signature) _verify;
  final DateTime Function() _now;

  /// How long a body may pause between pieces, and how long it may take in all from its first byte: one trickled a byte
  /// at a time would otherwise hold a connection, and a slot of [MarketConfig.bodiesInFlight], for ever. Caddy's own
  /// read_body timeout is for every site on the box, so this is the relay's to end. (Shorter in the tests.)
  final Duration _bodyPause, _bodyWhole;

  /// A body over [largeBody] holds one of the few slots while it is read, so it must keep coming: at least [largeBody]
  /// bytes (or the rest of it) in every [_bodyRateEvery] from when its slot is taken. A byte every 20 s kept within the
  /// pause and held a slot for its whole minute; three such, every slot, and nobody could send a screenshot (review,
  /// 2026-11-20). Any real upload of a submission sends that in a fraction of the time. (Shorter in the tests.)
  final Duration _bodyRateEvery;
  final Random _random;
  final MarketStore _store;

  /// A test's: run after a submission's files are written and before its record is made, the one wait in which another
  /// route (a decision) can come between the checks and the record. Null in the relay.
  Future<void> Function()? debugAfterWrites;

  /// A test's: run once a signed request's body is read, before its route has it. Null in the relay.
  void Function()? debugAfterRead;

  /// What a signed request signs: these words, its method, its path as asked (`/market/mine`), its time and the
  /// SHA-256 of its body (said up front in `x-ghost-body-sha256`; the empty body's for a GET or a DELETE).
  static String signedWords(String method, String path, int time, String bodySha) => 'ghost-market v1\n$method\n$path\n$time\n$bodySha';

  /// What a reviewer's approval signs: the plugin's id, version and the SHA-256 of its package's canonical bytes.
  static String approvalWords(String plugin, String version, String sha256) => 'ghost-market approve v1\n$plugin\n$version\n$sha256';

  /// What a withdrawal of one approved package signs, its reason with it, so the reason shown is the reviewer's own.
  static String revocationWords(String plugin, String sha256, int at, String why) => 'ghost-market revoke v1\n$plugin\n$sha256\n$at\n$why';

  /// What a review key signs to say it is no longer to be trusted.
  static String retirementWords(String key) => 'ghost-market retire v1\n$key';

  /// The SHA-256 of no bytes: what a signed GET or DELETE, which has no body, signs as its body's hash.
  static const emptySha = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

  /// How far a request's time may be from the relay's, and how long what it signed is remembered against its being
  /// sent again; at most [replaysKept] are, the oldest going first when it is full, never the request.
  static const skew = Duration(minutes: 5);
  static const replayLife = Duration(minutes: 10);
  static const replaysKept = 20000;

  /// A body larger than this counts against [MarketConfig.bodiesInFlight].
  static const largeBody = 64 * 1024;

  /// How lately the admin must have signed in to approve, list, withdraw or block.
  static const freshAdmin = Duration(minutes: 30);

  /// How long an id with no approved version is held after its last open submission closes.
  static const idHeld = Duration(days: 30);

  /// The most characters in a developer's notes to review or a report's text, a reviewer's note on a decision, a note
  /// on a listing or a block, and a withdrawal's reason.
  static const notesMost = 1000, decisionNoteMost = 2000, listingNoteMost = 500, whyMost = 200;

  /// How many reports are kept for one plugin, the newest; and the reasons a report may give.
  static const reportsKept = 200;
  static const reportReasons = {'misleading', 'harmful', 'spam', 'privacy', 'broken', 'other'};

  /// Reports of people and messages (GMFB-40): the most of a sealed envelope's base64, the fewest bytes one can be, and
  /// how many are kept (the oldest marked done going first, then the oldest). The app's own limits keep a report well
  /// under the most (lib/safety/abuse_report.dart).
  static const abuseSealedMost = 48000, abuseSealedLeast = 64, abuseKept = 150;

  /// Reports of people one key may send an hour and a day, one address and one someone (the number or account a key
  /// proved) a day; those with no verified number or linked account share [MarketConfig.reportsADay] a day in all.
  static const abuseByKeyAnHour = 5, abuseByKeyADay = 15, abuseByAddressADay = 20, abuseBySomeoneADay = 15;

  /// Route 22's body: a retirement and nothing more.
  static const retireMost = 4096;

  /// The most of route 3's list every app reads whole (lib/market/market_api.dart MarketReads, and the installer's
  /// takeRevocations): its bytes as served, its withdrawals and its retirements. An app refuses a list past any of them
  /// all at once and takes nothing from it, so from then on no withdrawal would reach a device but by a release
  /// (review, 2026-11-20): a withdrawal or a retirement that would take it past them is refused instead
  /// (withdrawals_full), where the reviewer sees it.
  static const withdrawalsMost = 8 * 1024 * 1024, revocationsMost = 25000, retirementsMost = 100;

  /// The answers and their words (the app checks `ok`, never the status alone: anything that isn't the market answers
  /// 200 "Uplink relay" as text).
  static const Map<String, (int, String)> errors = {
    'off': (503, 'The Marketplace isn\'t open on this server.'),
    'broken': (500, 'Something went wrong here. Try again later.'),
    'method': (405, 'That isn\'t a way to ask for this.'),
    'not_found': (404, 'There\'s nothing here by that name.'),
    'bad_request': (400, 'Something in that isn\'t right.'),
    'bad_json': (400, 'That couldn\'t be read.'),
    'too_large': (413, 'That\'s too large to send.'),
    'unsigned': (401, 'That needs the app\'s signature.'),
    'bad_signature': (401, 'The app\'s signature didn\'t check out. Make sure your clock is right, then try again.'),
    'busy': (503, 'Too much at once. Try again in a minute.'),
    'rate_limited': (429, 'That\'s a lot at once. Try again later.'),
    'must_agree': (400, 'Agree to the Marketplace guidelines first.'),
    'invalid_package': (400, 'The plugin has problems.'),
    'not_canonical': (400, 'The plugin file wasn\'t sent the way the app sends it.'),
    'bad_shot': (400, 'A screenshot isn\'t a PNG of 64 to 2,400 pixels a side and at most 1 MB, or the screenshots don\'t match the plugin\'s list of them.'),
    'not_owner': (403, 'The plugin\'s developer must be your own username, claimed on this device.'),
    'too_new': (403, 'A username can submit plugins a week after it\'s claimed.'),
    'blocked': (403, 'This account can\'t submit plugins.'),
    'needs_verified': (403, 'Verify your number in Settings first.'),
    'not_admin': (403, 'Sign in on Settings › Admin again to do that.'),
    'name_used': (409, 'Another developer has sent plugins under that username.'),
    'id_taken': (409, 'Another developer has a plugin with that id. Give yours another id in its file.'),
    'version_not_newer': (409, 'That version isn\'t newer than the one listed.'),
    'duplicate': (409, 'That exact plugin was sent already.'),
    'wrong_state': (409, 'That can\'t be done to it now.'),
    'admin_unlisted': (409, 'Review took it off the Marketplace: only review can list it again.'),
    'open_limit': (429, 'As many plugins are waiting for review as can wait at once. Try again when one is decided.'),
    'too_many_plugins': (429, 'That\'s as many plugins as one developer can have.'),
    'developer_full': (507, 'That\'s as much as one developer can keep in the Marketplace. Withdraw something first.'),
    'full': (507, 'The Marketplace is full just now.'),
    'withdrawals_full': (507, 'The list of withdrawals is as long as the app reads: no more can be added until it is made shorter.'),
    'bad_approval': (400, 'The approval\'s signature or its words don\'t match this plugin.'),
    'revoked': (410, 'This plugin was withdrawn.'),
  };

  // Done once start() has loaded the store: a request that comes before waits on it.
  final Completer<void> _ready = Completer();
  bool _started = false, _stopping = false;
  // Every minute, forgets counts that have run out; an hour after start and daily from then, the sweep.
  Timer? _pruner, _firstSweep, _sweeper;

  // In memory, and gone with a restart, as the relay's other counters are.
  // What each signed request signed (a hash of its key and words) -> when, oldest first, against its being sent again.
  // Then the counts each limit is held by: signed requests by address and by key, public reads and reads of the two
  // lists by address, retirements by address, a day's submissions and reports by who sent them and from where.
  final LinkedHashMap<String, int> _replays = LinkedHashMap();
  final _signedByAddress = _Windows(const Duration(minutes: 1));
  final _signedByKey = _Recent(const Duration(hours: 1));
  final _reads = _Windows(const Duration(minutes: 1));
  final _listReads = _Windows(const Duration(minutes: 1));
  final _retires = _Recent(const Duration(hours: 1));
  final _subsBySomeone = _Recent(const Duration(days: 1));
  final _subsByAddress = _Recent(const Duration(days: 1));
  final _reportsByKey = _Recent(const Duration(days: 1));
  final _reportsByKeyPlugin = _Recent(const Duration(days: 1));
  final _reportsByAddress = _Recent(const Duration(days: 1));
  final _reportsBySomeone = _Recent(const Duration(days: 1));
  final _reportsUnknown = _Recent(const Duration(days: 1));
  // Reports of people (`POST /market/abuse`): by key in an hour and a day, by address and by someone in a day, and
  // those from keys with no verified number or linked account, all together.
  final _abuseByKeyHour = _Recent(const Duration(hours: 1));
  final _abuseByKey = _Recent(const Duration(days: 1));
  final _abuseByAddress = _Recent(const Duration(days: 1));
  final _abuseBySomeone = _Recent(const Duration(days: 1));
  final _abuseUnknown = _Recent(const Duration(days: 1));
  int _verifySecond = -1, _verifiedThisSecond = 0;
  int _inFlight = 0, _inFlightBytes = 0;

  /// The addresses and keys with a large body being read: one each at a time. A key and an address cost a stranger
  /// nothing, and one of each held all three slots by trickling (review, 2026-11-20).
  final Set<String> _largeFrom = {}, _largeBy = {};
  int _verifications = 0;

  /// Route 8 one request at a time (and the sweep, which deletes what a submission might keep): two first submissions
  /// of one id give one 201 and one id_taken, and requests at once can't pass the quotas together.
  Future<void> _submitting = Future.value();

  // What each answer needs, made once a change and served from memory.
  Uint8List _catalog = Uint8List(0), _withdrawals = Uint8List(0);
  String _catalogTag = '', _withdrawalsTag = '';
  String? _catalogWords, _withdrawalsWords;
  // An approved package's SHA-256 -> its plugin's id and version. Then: the withdrawn packages' hashes, the retired
  // review keys, every key that signed an approval or a withdrawal kept here, and the listed plugins' screenshots.
  Map<String, (String, String)> _approved = {};
  Set<String> _revokedShas = {}, _retiredKeys = {}, _signers = {}, _listedShots = {};

  // Per request: whether an answer has begun, whether its body was read or let go, and whether it is a public read
  // (answered `no-cache`, where everything else is `no-store`).
  final Expando<bool> _answered = Expando(), _bodyTaken = Expando(), _publicAsk = Expando();

  /// Plugins listed now, for the start line.
  int get listed => _store.plugins.values.where((p) => p.listing == 'listed').length;

  /// Signature checks run since start: requests', approvals', withdrawals' and retirements'.
  int get verifications => _verifications;

  void _say(String what) {
    // Never an address, never a key.
    if (verbose) stdout.writeln('${_now().toIso8601String()} market $what');
  }

  int _ms() => _now().millisecondsSinceEpoch;

  /// Loads state.json, counts what is on disk, and starts the daily sweep (the first an hour after start).
  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      await _store.load();
    } catch (e) {
      stderr.writeln('market: ${dir.path} could not be read: $e');
    }
    for (final d in _store.developers.values) {
      d.bytes = _bytesOf(d.id);
    }
    _rebuild();
    _ready.complete();
    _pruner = Timer.periodic(const Duration(minutes: 1), (_) => _prune());
    _firstSweep = Timer(const Duration(hours: 1), () {
      unawaited(_sweepQuietly());
      _sweeper = Timer.periodic(const Duration(days: 1), (_) => unawaited(_sweepQuietly()));
    });
  }

  /// Saves, synchronously, and stops the sweep. New requests are answered busy from now, and route 8's queue is let
  /// finish first (10 s at most): stopped in the middle of a submission's writes, the relay answered it 201 and its
  /// record was never saved, the id it had made held for good (review, 2026-11-20). Whatever still finishes after the
  /// last save is written as it does (market_store.dart).
  Future<void> stop() async {
    _stopping = true;
    _pruner?.cancel();
    _firstSweep?.cancel();
    _sweeper?.cancel();
    try {
      await _submitting.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      // Saved as it stands; what finishes later is written as it does.
    }
    await _store.close();
  }

  /// Saved now, for the tests: state.json as the market stands.
  Future<void> flush() => _store.flush();

  /// Every request whose first path segment is 'market'. Never throws: an Error too (a stack overflow) is caught,
  /// written as one line to stderr, and answered 500 broken while the answer is still to be sent, since anything that
  /// escaped would end the relay, and with it every hub connection.
  Future<void> handle(HttpRequest r) async {
    try {
      await _handle(r);
    } catch (e, st) {
      try {
        stderr.writeln('${_now().toUtc().toIso8601String()} market: ${'$e'.split('\n').first} at ${'$st'.split('\n').first.trim()}');
      } catch (_) {}
      if (_answered[r] != true) {
        try {
          await _refuse(r, 'broken');
        } catch (_) {}
      }
    }
  }

  /// Routes by number ([_routeOf]; the numbers are docs/marketplace.md's). Public, unsigned: 1 `GET /market` (limits
  /// and whether it is open), 2 `GET /catalog`, 3 `GET /revoked` (withdrawals and retired keys), 4 `GET /packages/<sha>`,
  /// 6 `GET /shots/<sha>`, 22 `POST /retire`. Signed, from anyone: 7 `POST /report`. Signed, a developer's: 8
  /// `POST /submissions`, 9 `GET /mine`, 10 `GET /submissions/<sid>`, 11 `…/package`, 12 `…/shots/<n>`, 13
  /// `DELETE /submissions/<sid>` (withdraw), 17 `POST /plugins/<id>/listing` (review's too). Signed, review's: 14
  /// `GET /review` (the queue), 15 `GET /review/<sid>`, 16 `POST /review/<sid>` (a decision), 18
  /// `POST /plugins/<id>/revoke`, 19 `GET /reports`, 20 `POST /reports/<rid>`, 21 `POST /developers/<id>/block`.
  /// Review may read 10 to 12 as well. A refusal anywhere below is thrown as [_Refused] and answered here.
  Future<void> _handle(HttpRequest r) async {
    await _ready.future;
    var parts = r.uri.pathSegments.skipWhile((s) => s.isEmpty).skip(1).toList();
    if (parts.length == 1 && parts.single.isEmpty) parts = const [];
    final (route, args) = _routeOf(r.method, parts);
    _publicAsk[r] = const {1, 2, 3, 4, 6}.contains(route);
    try {
      if (_stopping) throw const _Refused('busy');
      if (route == null) throw const _Refused('not_found');
      if (route == 0) throw const _Refused('method');
      if (route != 1 && !config.on) throw const _Refused('off');
      switch (route) {
        case 1:
          return await _info(r);
        case 2:
          return await _list(r, _catalog, _catalogTag);
        case 3:
          return await _list(r, _withdrawals, _withdrawalsTag);
        case 4:
          return await _package(r, args!);
        case 6:
          return await _shot(r, args!);
        case 22:
          return await _retire(r);
      }
      final a = await _signed(r);
      try {
        switch (route) {
          case 7:
            return await _report(r, a);
          case 8:
            return await _oneAtATime(() => _submit(r, a));
          case 9:
            return await _mine(r, a);
          case 10:
            return await _answer(r, 200, {'ok': true, 'submission': _view(_submissionFor(a, args!))});
          case 11:
            return await _submissionPackage(r, a, args!);
          case 12:
            return await _submissionShot(r, a, args!);
          case 13:
            return await _withdraw(r, a, args!);
          case 14:
            return await _queue(r, a);
          case 15:
            return await _item(r, a, args!);
          case 16:
            return await _decide(r, a, args!);
          case 17:
            return await _listing(r, a, args!);
          case 18:
            return await _revoke(r, a, args!);
          case 19:
            return await _reports(r, a);
          case 20:
            return await _resolve(r, a, args!);
          case 21:
            return await _block(r, a, args!);
          case 23:
            return await _abuseReport(r, a);
          case 24:
            return await _abuseList(r, a);
          case 25:
            return await _abuseResolve(r, a, args!);
        }
      } finally {
        // A large body's slot is the route's until it is done with the body: route 8 waits its turn with the body read,
        // and given back as the read ended, any number of read bodies waited there past the bound of 3 × maxBody
        // (review, 2026-11-20).
        a.release();
      }
    } on _Refused catch (e) {
      return _refuse(r, e.code, issues: e.issues);
    }
  }

  // The shapes a path's parts must have: a SHA-256, a submission's id, a report's id, a developer's hub id, and a
  // screenshot's number (one digit).
  static final _hex64 = RegExp(r'^[0-9a-f]{64}$');
  static final _sid = RegExp(r'^[0-9a-f]{24}$');
  static final _rid = RegExp(r'^[0-9a-f]{16}$');
  static final _devId = RegExp(r'^[0-9a-f]{32}$');
  static final _digit = RegExp(r'^[0-9]$');

  /// The route [method] asks for at [p] (the path after /market), with what its path names: 0 where the path is one
  /// asked another way, null where it is none. A sid, a hash or a screenshot's number that isn't of its shape is no
  /// path at all, never parsed as a number first.
  (int?, String?) _routeOf(String method, List<String> p) {
    int way(Map<String, int> ways) => ways[method] ?? 0;
    switch (p) {
      case []:
        return (way({'GET': 1}), null);
      case ['catalog']:
        return (way({'GET': 2}), null);
      case ['revoked']:
        return (way({'GET': 3}), null);
      case ['packages', final sha] when _hex64.hasMatch(sha):
        return (way({'GET': 4}), sha);
      case ['shots', final sha] when _hex64.hasMatch(sha):
        return (way({'GET': 6}), sha);
      case ['report']:
        return (way({'POST': 7}), null);
      case ['submissions']:
        return (way({'POST': 8}), null);
      case ['mine']:
        return (way({'GET': 9}), null);
      case ['submissions', final sid] when _sid.hasMatch(sid):
        return (way({'GET': 10, 'DELETE': 13}), sid);
      case ['submissions', final sid, 'package'] when _sid.hasMatch(sid):
        return (way({'GET': 11}), sid);
      case ['submissions', final sid, 'shots', final n] when _sid.hasMatch(sid) && _digit.hasMatch(n):
        return (way({'GET': 12}), '$sid/$n');
      case ['review']:
        return (way({'GET': 14}), null);
      case ['review', final sid] when _sid.hasMatch(sid):
        return (way({'GET': 15, 'POST': 16}), sid);
      case ['plugins', final id, 'listing'] when packIdPattern.hasMatch(id):
        return (way({'POST': 17}), id);
      case ['plugins', final id, 'revoke'] when packIdPattern.hasMatch(id):
        return (way({'POST': 18}), id);
      case ['reports']:
        return (way({'GET': 19}), null);
      case ['reports', final rid] when _rid.hasMatch(rid):
        return (way({'POST': 20}), rid);
      case ['developers', final dev, 'block'] when _devId.hasMatch(dev):
        return (way({'POST': 21}), dev);
      case ['retire']:
        return (way({'POST': 22}), null);
      case ['abuse']:
        return (way({'POST': 23, 'GET': 24}), null);
      case ['abuse', final rid] when _rid.hasMatch(rid):
        return (way({'POST': 25}), rid);
    }
    return (null, null);
  }

  // --- answering ------------------------------------------------------------------------------------------------------

  static final _jsonType = ContentType('application', 'json', charset: 'utf-8');

  /// The headers on every JSON answer: nothing in it is to be run, framed or sniffed as another type by a browser.
  Map<String, String> _jsonHeaders(HttpRequest r) => {
        'X-Content-Type-Options': 'nosniff',
        'Content-Security-Policy': "default-src 'none'; frame-ancestors 'none'; sandbox",
        'Referrer-Policy': 'no-referrer',
        'Cache-Control': _publicAsk[r] == true ? 'no-cache' : 'no-store',
      };

  /// Sends an answer whole, with its length, and marks [r] answered so [handle] doesn't answer it again.
  Future<void> _send(HttpRequest r, int status, List<int> bytes, {ContentType? type, required Map<String, String> headers}) async {
    _answered[r] = true;
    final res = r.response..statusCode = status;
    if (type != null) res.headers.contentType = type;
    headers.forEach(res.headers.set);
    res.contentLength = bytes.length;
    if (bytes.isNotEmpty) res.add(bytes);
    try {
      await res.close();
    } on IOException {
      // Whoever asked has gone: nothing to tell, and nothing wrong here.
    }
  }

  Future<void> _answer(HttpRequest r, int status, Map<String, Object?> body) => _send(r, status, utf8.encode(jsonEncode(body)), type: _jsonType, headers: _jsonHeaders(r));

  /// An error of [errors], with the pack's [issues] for invalid_package. Before its body is read, the request is let go
  /// of unread, with its connection: dart:io holds an answer back until the body is read otherwise, and a refused
  /// request must cost the relay nothing more.
  Future<void> _refuse(HttpRequest r, String code, {List<PackIssue>? issues}) {
    final (status, message) = errors[code]!;
    if (_bodyTaken[r] != true) {
      _bodyTaken[r] = true;
      try {
        r.listen(null).cancel();
        r.response.persistentConnection = false;
      } catch (_) {}
    }
    return _answer(r, status, {'ok': false, 'error': code, 'message': message, if (issues != null) 'issues': [for (final i in issues) i.toJson()]});
  }

  /// A package or a screenshot: never anything a browser would run, whatever its bytes say.
  Future<void> _file(HttpRequest r, List<int> bytes, {required String type, required String disposition, required bool public}) => _send(r, 200, bytes, type: ContentType.parse(type), headers: {
        'X-Content-Type-Options': 'nosniff',
        'Content-Security-Policy': "default-src 'none'; sandbox",
        'Content-Disposition': disposition,
        'Cache-Control': public ? 'public, max-age=31536000, immutable' : 'no-store',
      });

  // --- signed requests ------------------------------------------------------------------------------------------------

  /// Who signed [r], everything checked before a byte of its body is read, cheapest first, so a stranger's request
  /// costs one header parse, not a 6 MiB buffer and a P-256 check: the route (already), the headers, the key's and
  /// signature's shapes and the time, the declared length, a replay, the address's budget, the relay's signature budget,
  /// a large body's slot, the signature, then the key's own budget. Only then is the body read, held to its hash.
  Future<_Asker> _signed(HttpRequest r) async {
    final h = r.headers;
    // Each at most once: dart:io's value() throws where a header comes twice, which reached handle()'s catch-all as a
    // 500 broken and a line on stderr for each such request, a stranger's at no cost (review, 2026-11-20).
    String? one(String name) {
      final v = h[name];
      if (v == null || v.isEmpty) return null;
      if (v.length > 1) throw const _Refused('bad_request');
      return v.single;
    }

    final keyText = one('x-ghost-key'), timeText = one('x-ghost-time'), sigText = one('x-ghost-sig');
    if (keyText == null || timeText == null || sigText == null) throw const _Refused('unsigned');
    if (r.uri.hasQuery) throw const _Refused('bad_request');
    final said = one(Files.bodyShaHeader)?.trim(), saidLength = one(Files.bodyLengthHeader)?.trim();
    final String bodySha;
    final int length;
    if (r.method == 'GET' || r.method == 'DELETE') {
      if (said != null || saidLength != null || r.contentLength > 0 || h.chunkedTransferEncoding) throw const _Refused('bad_request');
      bodySha = emptySha;
      length = 0;
    } else {
      final n = saidLength == null ? null : int.tryParse(saidLength);
      if (said == null || n == null || !_hex64.hasMatch(said) || n < 0 || n != r.contentLength) throw const _Refused('bad_request');
      bodySha = said;
      length = n;
    }
    final now = _ms();
    final List<int> key, sig;
    try {
      key = base64Decode(keyText.trim());
      sig = base64Decode(sigText.trim());
    } catch (_) {
      throw const _Refused('bad_signature');
    }
    final time = int.tryParse(timeText.trim());
    if (key.length != 33 || (key[0] != 2 && key[0] != 3) || sig.length != 64 || time == null || (now - time).abs() > skew.inMilliseconds) throw const _Refused('bad_signature');
    if (length > config.maxBody) throw const _Refused('too_large');
    final words = utf8.encode(signedWords(r.method, r.uri.path, time, bodySha));
    // Remembered by what was signed, not by the signature, which has a twin (s and n - s) that checks out as well.
    final replay = hexOf(sha256([...key, ...words]));
    _pruneReplays(now);
    if (_replays.containsKey(replay)) throw const _Refused('bad_signature');
    final address = Files.addressOf(r);
    if (!_signedByAddress.take(address, config.signedPerAddress, now)) throw const _Refused('rate_limited');
    if (!_mayVerify(now)) throw const _Refused('busy');
    final large = length > largeBody;
    final keyB64 = base64Encode(key);
    if (large) {
      if (_largeFrom.contains(address) || _largeBy.contains(keyB64)) throw const _Refused('rate_limited');
      if (_inFlight >= config.bodiesInFlight || _inFlightBytes + length > config.bodiesInFlight * config.maxBody) throw const _Refused('busy');
      _inFlight++;
      _inFlightBytes += length;
      _largeFrom.add(address);
      _largeBy.add(keyB64);
    }
    // The slot, given back once: here where the request goes no further, else by its route once it is done with the
    // body (handle).
    var holding = large;
    void release() {
      if (!holding) return;
      holding = false;
      _inFlight--;
      _inFlightBytes -= length;
      _largeFrom.remove(address);
      _largeBy.remove(keyB64);
    }

    var handed = false;
    try {
      _verifications++;
      if (!_verify(key, words, sig)) throw const _Refused('bad_signature');
      final id = FilesRoster.idOf(key);
      _replays[replay] = now;
      while (_replays.length > replaysKept) {
        _replays.remove(_replays.keys.first);
      }
      if (!_signedByKey.take(id, config.signedAnHour, now)) throw const _Refused('rate_limited');
      final body = await _readBody(r, length, sha: bodySha, steady: large);
      debugAfterRead?.call();
      handed = true;
      return _Asker(id: id, key: keyB64, body: body, address: address, release: release);
    } finally {
      if (!handed) release();
    }
  }

  /// Forgets signed requests older than [replayLife]: past [skew] their time alone refuses them.
  void _pruneReplays(int now) {
    while (_replays.isNotEmpty && now - _replays.values.first >= replayLife.inMilliseconds) {
      _replays.remove(_replays.keys.first);
    }
  }

  /// Whether one more signature may be checked this second ([MarketConfig.verifyASecond]); counts it where so.
  bool _mayVerify(int now) {
    final second = now ~/ 1000;
    if (second != _verifySecond) {
      _verifySecond = second;
      _verifiedThisSecond = 0;
    }
    if (_verifiedThisSecond >= config.verifyASecond) return false;
    _verifiedThisSecond++;
    return true;
  }

  /// The body, [length] bytes, into a BytesBuilder (never a List<int>, at 8 bytes a byte), hashed as it comes: whole
  /// within [_bodyWhole] of its first byte with no pause over [_bodyPause], [steady] (a large body, holding a slot)
  /// at least [largeBody] bytes or the rest of it every [_bodyRateEvery], and, with [sha], hashing to it.
  Future<Uint8List> _readBody(HttpRequest r, int length, {String? sha, bool steady = false}) async {
    _bodyTaken[r] = true;
    final out = BytesBuilder(copy: false);
    final hash = Sha256();
    final done = Completer<bool>();
    Timer? pause, whole, rate;
    void end(bool ok) {
      if (!done.isCompleted) done.complete(ok);
    }

    void waiting() {
      pause?.cancel();
      pause = Timer(_bodyPause, () => end(false));
    }

    waiting();
    if (steady) {
      var mark = 0;
      rate = Timer.periodic(_bodyRateEvery, (_) {
        if (out.length - mark < min(largeBody, length - mark)) return end(false);
        mark = out.length;
      });
    }
    final sub = r.listen(
      (piece) {
        whole ??= Timer(_bodyWhole, () => end(false));
        if (out.length + piece.length > length) return end(false);
        out.add(piece);
        hash.add(piece);
        waiting();
      },
      onError: (Object _) => end(false),
      onDone: () => end(true),
      cancelOnError: true,
    );
    final ok = await done.future;
    pause?.cancel();
    whole?.cancel();
    rate?.cancel();
    if (!ok || out.length != length) {
      unawaited(sub.cancel().then((_) {}, onError: (Object _) {}));
      r.response.persistentConnection = false;
      throw const _Refused('bad_request');
    }
    if (sha != null && hexOf(hash.close()) != sha) throw const _Refused('bad_request');
    return out.takeBytes();
  }

  /// [body] as a JSON object, its nesting checked before it is decoded; bad_json otherwise.
  static Map<String, Object?> _object(Uint8List body) {
    if (jsonDepthOk(body)) {
      try {
        final j = jsonDecode(utf8.decode(body));
        if (j is Map<String, Object?>) return j;
      } catch (_) {}
    }
    throw const _Refused('bad_json');
  }

  /// Refuses not_admin unless [a] is signed in to the admin page; [fresh], within the last [freshAdmin].
  void _admin(_Asker a, {bool fresh = false}) {
    if (!(fresh ? adminSignedIn(a.id, within: freshAdmin) : adminSignedIn(a.id))) throw const _Refused('not_admin');
  }

  /// Whether [key]'s [sig] (both base64) is over [words]: a review key's approval, withdrawal or retirement.
  bool _signedBy(String key, String words, String sig) {
    final k = strictBase64(key), s = strictBase64(sig);
    if (k == null || s == null || k.length != 33 || (k[0] != 2 && k[0] != 3) || s.length != 64) return false;
    _verifications++;
    return _verify(k, utf8.encode(words), s);
  }

  /// Runs [work] after everything queued before it has finished, failed or not ([_submitting]).
  Future<T> _oneAtATime<T>(Future<T> Function() work) {
    final run = _submitting.then((_) => work());
    _submitting = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  /// A random id of [bytes] bytes in hex that isn't [taken].
  String _newId(int bytes, bool Function(String) taken) {
    while (true) {
      final id = hexOf([for (var i = 0; i < bytes; i++) _random.nextInt(256)]);
      if (!taken(id)) return id;
    }
  }

  // --- public reads ---------------------------------------------------------------------------------------------------

  /// A public read from [r]'s address: [MarketConfig.readsPerMinute] of them a minute, and of the catalog and the
  /// withdrawals ([list]) ten, 304s included.
  void _read(HttpRequest r, {bool list = false}) {
    final now = _ms();
    final address = Files.addressOf(r);
    if (!_reads.take(address, config.readsPerMinute, now)) throw const _Refused('rate_limited');
    if (list && !_listReads.take(address, 10, now)) throw const _Refused('rate_limited');
  }

  /// Route 1: whether the Marketplace is open here, its limits, and the labels, shelves, hues and permissions a
  /// package may name, so the app's submission form checks against what this server takes.
  Future<void> _info(HttpRequest r) {
    _read(r);
    return _answer(r, 200, {
      'ok': true,
      'market': 1,
      'format': packFormat,
      'open': config.on,
      'limits': {'package': config.maxPackage, 'icon': PackLimits.iconChars, 'shot': config.maxShot, 'shotSide': PackLimits.shotMax, 'shots': config.maxShots, 'body': config.maxBody, 'notes': notesMost},
      'labels': packLabels,
      'shelves': packShelves,
      'hues': packHues,
      'permissions': packPermissions,
    });
  }

  /// The catalog or the withdrawals, from memory, 304 where the asker has them already.
  Future<void> _list(HttpRequest r, Uint8List bytes, String tag) {
    _read(r, list: true);
    final headers = {..._jsonHeaders(r), 'ETag': tag};
    final has = r.headers[HttpHeaders.ifNoneMatchHeader]?.expand((v) => v.split(',')).map((t) => t.trim().replaceFirst('W/', ''));
    if (has != null && has.contains(tag)) return _send(r, HttpStatus.notModified, const [], headers: headers);
    return _send(r, 200, bytes, type: _jsonType, headers: headers);
  }

  /// Route 4: an approved package by its SHA-256, listed or not (whoever has an earlier version can still fetch it);
  /// 410 once it is withdrawn.
  Future<void> _package(HttpRequest r, String sha) async {
    _read(r);
    final of = _approved[sha];
    if (of == null) throw const _Refused('not_found');
    if (_revokedShas.contains(sha)) throw const _Refused('revoked');
    final bytes = await _store.readBlob('packages', sha);
    if (bytes == null) throw const _Refused('not_found');
    return _file(r, bytes, type: 'application/octet-stream', disposition: 'attachment; filename="${of.$1}-${of.$2}.ghostplugin"', public: true);
  }

  /// Route 6: a screenshot of a listed plugin's current version, by its SHA-256.
  Future<void> _shot(HttpRequest r, String sha) async {
    _read(r);
    if (!_listedShots.contains(sha)) throw const _Refused('not_found');
    final bytes = await _store.readBlob('shots', sha);
    if (bytes == null) throw const _Refused('not_found');
    return _file(r, bytes, type: 'image/png', disposition: 'inline', public: true);
  }

  // --- reports --------------------------------------------------------------------------------------------------------

  static final _username = packUsernamePattern;

  /// Who [id] is counted as: the number or account it proved, else its key alone.
  String _someone(String id) => whoOf(id) ?? 'key|$id';

  /// Route 7: a report of an approved plugin, from anyone with the app. Held to a few a day by key, by key and plugin,
  /// by address and by the someone behind the key (10, 3, 5, 5), and in all from senders with no verified number or
  /// linked account ([MarketConfig.reportsADay]).
  Future<void> _report(HttpRequest r, _Asker a) async {
    final j = _object(a.body);
    final plugin = j['plugin'], version = j['version'], reason = j['reason'], text = j.containsKey('text') ? j['text'] : '', username = j['username'];
    final shaped = j.keys.every(const {'plugin', 'version', 'reason', 'text', 'username'}.contains) &&
        plugin is String &&
        packIdPattern.hasMatch(plugin) &&
        version is String &&
        packVersionPattern.hasMatch(version) &&
        reason is String &&
        reportReasons.contains(reason) &&
        text is String &&
        text.length <= notesMost &&
        packTextOk(text, newlines: true) &&
        (!j.containsKey('username') || (username is String && _username.hasMatch(username) && !username.contains('..')));
    if (!shaped) throw const _Refused('bad_request');
    final p = _store.plugins[plugin];
    if (p == null || p.versions.isEmpty) throw const _Refused('not_found');
    final now = _ms();
    final known = whoOf(a.id) != null;
    final someone = _someone(a.id);
    final pair = '${a.id}|$plugin';
    if (_reportsByKey.count(a.id, now) >= 10 ||
        _reportsByKeyPlugin.count(pair, now) >= 3 ||
        _reportsByAddress.count(a.address, now) >= 5 ||
        _reportsBySomeone.count(someone, now) >= 5 ||
        (!known && _reportsUnknown.count('', now) >= config.reportsADay)) {
      throw const _Refused('rate_limited');
    }
    _reportsByKey.add(a.id, now);
    _reportsByKeyPlugin.add(pair, now);
    _reportsByAddress.add(a.address, now);
    _reportsBySomeone.add(someone, now);
    if (!known) _reportsUnknown.add('', now);
    final rid = _newId(8, _store.reports.containsKey);
    final name = username as String?;
    // Who sent it is counted above, in memory for the day, and never kept: the app and the privacy page say the
    // username goes with a report only if they choose, and its key's id kept with it said whose it was all the same
    // (review, 2026-11-20).
    _store.reports[rid] = MarketReport(rid: rid, plugin: plugin, version: version, reason: reason, text: text, username: name, verified: name != null && ownsName(a.id, name), at: now);
    // The newest of each plugin's kept: the map is in the order they came.
    final its = [for (final x in _store.reports.values) if (x.plugin == plugin) x.rid];
    for (var i = 0; i < its.length - reportsKept; i++) {
      _store.reports.remove(its[i]);
    }
    _changed();
    _store.audit('reporter', 'report', plugin: plugin, note: reason);
    return _answer(r, 201, {'ok': true, 'id': rid});
  }

  /// A report as review is shown it.
  Map<String, Object?> _reportView(MarketReport x) => {'rid': x.rid, 'plugin': x.plugin, 'version': x.version, 'reason': x.reason, 'text': x.text, 'username': x.username, 'verified': x.verified, 'at': x.at, 'done': x.done, 'doneAt': x.doneAt};

  /// Route 19, review's: the newest 500 reports, newest first.
  Future<void> _reports(HttpRequest r, _Asker a) {
    _admin(a);
    return _answer(r, 200, {
      'ok': true,
      'reports': [for (final x in _store.reports.values.toList().reversed.take(500)) _reportView(x)],
    });
  }

  /// Route 20, review's: marks a report dealt with (`{"done": true}`); it stays in the list.
  Future<void> _resolve(HttpRequest r, _Asker a, String rid) {
    _admin(a);
    final j = _object(a.body);
    if (j.length != 1 || j['done'] != true) throw const _Refused('bad_request');
    final x = _store.reports[rid];
    if (x == null) throw const _Refused('not_found');
    if (!x.done) {
      x.done = true;
      x.doneAt = _ms();
      _changed();
      _store.audit(a.id, 'resolve', plugin: x.plugin, note: rid);
    }
    return _answer(r, 200, {'ok': true});
  }

  // --- reports of people and messages (GMFB-40) -----------------------------------------------------------------------

  /// Route 23: a report of a person or a message, sealed in the app to the review keys so only the reviewer reads it
  /// (lib/safety/abuse_report.dart): `{sealed: <base64>}` and nothing else. The relay can't read it and doesn't try;
  /// it holds the sender to its limits and keeps the envelope, never who sent it.
  Future<void> _abuseReport(HttpRequest r, _Asker a) async {
    final j = _object(a.body);
    final sealed = j['sealed'];
    if (j.length != 1 || sealed is! String) throw const _Refused('bad_request');
    if (sealed.length > abuseSealedMost) throw const _Refused('too_large');
    final bytes = strictBase64(sealed);
    if (bytes == null || bytes.length < abuseSealedLeast) throw const _Refused('bad_request');
    final now = _ms();
    final known = whoOf(a.id) != null;
    final someone = _someone(a.id);
    if (_abuseByKeyHour.count(a.id, now) >= abuseByKeyAnHour ||
        _abuseByKey.count(a.id, now) >= abuseByKeyADay ||
        _abuseByAddress.count(a.address, now) >= abuseByAddressADay ||
        _abuseBySomeone.count(someone, now) >= abuseBySomeoneADay ||
        (!known && _abuseUnknown.count('', now) >= config.reportsADay)) {
      throw const _Refused('rate_limited');
    }
    _abuseByKeyHour.add(a.id, now);
    _abuseByKey.add(a.id, now);
    _abuseByAddress.add(a.address, now);
    _abuseBySomeone.add(someone, now);
    if (!known) _abuseUnknown.add('', now);
    final rid = _newId(8, _store.abuse.containsKey);
    _store.abuse[rid] = MarketAbuse(rid: rid, sealed: sealed, at: now);
    // Past the most kept: the oldest marked done goes first, else the oldest.
    while (_store.abuse.length > abuseKept) {
      final going = _store.abuse.values.where((x) => x.done).firstOrNull ?? _store.abuse.values.first;
      _store.abuse.remove(going.rid);
    }
    _store.changed();
    _store.audit('reporter', 'abuse', note: rid);
    return _answer(r, 201, {'ok': true, 'id': rid});
  }

  /// Route 24: the reports of people, newest first, for review to open with its own key.
  Future<void> _abuseList(HttpRequest r, _Asker a) {
    _admin(a);
    return _answer(r, 200, {
      'ok': true,
      'reports': [for (final x in _store.abuse.values.toList().reversed) {'rid': x.rid, 'sealed': x.sealed, 'at': x.at, 'done': x.done, 'doneAt': x.doneAt}],
    });
  }

  /// Route 25: a report of a person dealt with.
  Future<void> _abuseResolve(HttpRequest r, _Asker a, String rid) {
    _admin(a);
    final j = _object(a.body);
    if (j.length != 1 || j['done'] != true) throw const _Refused('bad_request');
    final x = _store.abuse[rid];
    if (x == null) throw const _Refused('not_found');
    if (!x.done) {
      x.done = true;
      x.doneAt = _ms();
      _store.changed();
      _store.audit(a.id, 'abuse_done', note: rid);
    }
    return _answer(r, 200, {'ok': true});
  }

  // --- submissions ----------------------------------------------------------------------------------------------------

  /// Whether [e] is a screenshot as a submission sends one: `{mime, data}` (base64), or `{keep: <sha256>}` for one of
  /// the plugin's that is here already.
  static bool _shotShaped(Object? e) => e is Map && ((e.length == 2 && e['mime'] is String && e['data'] is String) || (e.length == 1 && e['keep'] is String));

  /// What [devId]'s kept submissions hold on disk ('packages/<sha256>', 'shots/<sha256>').
  Set<String> _blobsOf(String devId) => {
        for (final s in _store.submissions.values)
          if (s.owner == devId && !s.swept) ...['packages/${s.sha256}', for (final x in s.shots) 'shots/${x.sha256}'],
      };

  /// How many bytes those are, each file counted once ([MarketConfig.bytesPerDeveloper]).
  int _bytesOf(String devId) => _blobsOf(devId).fold(0, (n, name) => n + (_store.blobs[name] ?? 0));

  /// Whether a submission of [plugin] is still open: sent, in review, or sent back for changes.
  bool _hasOpen(String plugin) => _store.submissions.values.any((s) => s.plugin == plugin && s.open);

  /// Route 8, one at a time, its checks in order: who may submit, the request, the package's bytes, its top level, the
  /// username, the id, the version, the screenshots, the quotas; a check stops there; then it is kept.
  Future<void> _submit(HttpRequest r, _Asker a) async {
    final now = _now();
    final at = now.millisecondsSinceEpoch;
    if (_store.developers[a.id]?.blocked ?? false) throw const _Refused('blocked');
    final who = whoOf(a.id);
    if (config.needVerified && who == null) throw const _Refused('needs_verified');
    final claimed = claimedOn(a.id);
    if (claimed != null && now.isBefore(claimed.add(Duration(days: config.nameAgeDays)))) throw const _Refused('too_new');

    final j = _object(a.body);
    final check = j.containsKey('check');
    var shots = const <Object?>[];
    var notes = '';
    var list = 'now';
    // `{check: true, package}` asks only whether the package would be taken: every check below is run, nothing is
    // kept. A real submission carries its screenshots, notes to review, when to list it, and `agree`.
    if (check) {
      if (j.length != 2 || j['check'] != true || j['package'] is! String) throw const _Refused('bad_request');
    } else {
      if (!j.keys.every(const {'package', 'shots', 'notes', 'list', 'agree'}.contains) || j['package'] is! String) throw const _Refused('bad_request');
      final s = j.containsKey('shots') ? j['shots'] : const <Object?>[];
      if (s is! List || s.length > config.maxShots || !s.every(_shotShaped)) throw const _Refused('bad_request');
      shots = s;
      final n = j.containsKey('notes') ? j['notes'] : '';
      if (n is! String || n.length > notesMost || !packTextOk(n, newlines: true)) throw const _Refused('bad_request');
      notes = n;
      final l = j.containsKey('list') ? j['list'] : 'now';
      if (l != 'now' && l != 'later') throw const _Refused('bad_request');
      list = l as String;
      if (j['agree'] != true) throw const _Refused('must_agree');
    }

    final package = strictBase64(j['package'] as String);
    if (package == null) throw const _Refused('bad_request');
    if (package.length > config.maxPackage) throw const _Refused('too_large');
    if (!jsonDepthOk(package)) throw _Refused('invalid_package', issues: [PackIssue('too_deep', '', 'The file nests lists and objects deeper than ${PackLimits.depth}.')]);
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(package));
    } catch (e) {
      throw _Refused('invalid_package', issues: [PackIssue('bad_json', '', 'The file isn\'t UTF-8 JSON: ${'$e'.split('\n').first}')]);
    }
    // The bytes sent must be the one way this JSON is written (market_pack.dart): an approval signs their SHA-256,
    // so two spellings of one package would be two packages.
    try {
      if (!_same(canonicalBytes(decoded), package)) throw const _Refused('not_canonical');
    } on ArgumentError {
      throw const _Refused('not_canonical');
    }
    final (:issues, :top) = checkPackTop(decoded, needIcon: !check, needSupport: !check);
    if (top == null) throw _Refused('invalid_package', issues: issues);
    final sha = hexOf(sha256(package));

    if (!ownsName(a.id, top.developer)) throw const _Refused('not_owner');
    // Every name another developer's plugins were sent under, not only the first: one who renamed and sent an update
    // under the new name, approved and listed "By @" it, left that name free for whoever claimed it after them, and
    // two keys' plugins were listed under one name (review, 2026-11-20). An id let go frees the names it was sent under.
    if (_store.plugins.values.any((p) => p.owner != a.id && p.developer == top.developer) ||
        _store.submissions.values.any((s) => s.owner != a.id && s.manifest['developer'] == top.developer && _store.plugins[s.plugin]?.owner == s.owner)) {
      throw const _Refused('name_used');
    }

    final plugin = _store.plugins[top.id];
    if (plugin != null && plugin.owner != a.id) throw const _Refused('id_taken');
    if (plugin == null) {
      // An owner the audit remembers for an id with no record: a state started empty can't hand it to someone else.
      final held = _store.auditOwners[top.id];
      if (held != null && held != a.id) throw const _Refused('id_taken');
    }
    // An id joins the counts as it opens: a new one, or one held for its owner with nothing approved and nothing
    // waiting (withdrawn or rejected, kept 30 days). Counted for new ids alone, a developer at the cap could withdraw
    // ids and open them again later past both limits (review, 2026-11-20).
    if (plugin == null || (plugin.versions.isEmpty && !_hasOpen(plugin.id))) {
      final mine = _store.plugins.values.where((p) => p.owner == a.id && (p.versions.isNotEmpty || _hasOpen(p.id))).length;
      final approved = _store.plugins.values.where((p) => p.versions.isNotEmpty).length;
      if (mine >= config.pluginsPerDeveloper || approved >= config.maxPlugins) throw const _Refused('too_many_plugins');
    }

    final current = plugin?.current;
    if (current != null && compareVersions(top.version, current.version) <= 0) throw const _Refused('version_not_newer');
    if (_store.submissions.values.any((s) => s.plugin == top.id && s.sha256 == sha)) throw const _Refused('duplicate');

    final taken = <({String sha256, int size, Uint8List? bytes})>[];
    if (!check) {
      for (final e in shots) {
        final m = e as Map;
        if (m.containsKey('keep')) {
          // One of this developer's own earlier screenshots of this plugin, still on disk: an update needn't send its
          // pictures again.
          final keep = m['keep'] as String;
          final had = [
            for (final s in _store.submissions.values)
              if (s.plugin == top.id && s.owner == a.id && !s.swept) ...s.shots,
          ].where((x) => x.sha256 == keep).firstOrNull;
          if (had == null || !_store.has('shots', keep)) throw const _Refused('bad_shot');
          taken.add((sha256: keep, size: had.size, bytes: null));
        } else {
          final bytes = m['mime'] == 'image/png' ? strictBase64(m['data'] as String) : null;
          if (bytes == null || bytes.length > config.maxShot || pngProblem(bytes, min: PackLimits.shotMin, max: PackLimits.shotMax) != null) throw const _Refused('bad_shot');
          taken.add((sha256: hexOf(sha256(bytes)), size: bytes.length, bytes: bytes));
        }
      }
      // The package lists the screenshots its page shows, so an approval covers which pictures those are.
      if (taken.length != top.shots.length || [for (var i = 0; i < taken.length; i++) taken[i].sha256 != top.shots[i]].any((x) => x)) throw const _Refused('bad_shot');
    }

    final someone = who ?? 'key|${a.id}';
    if (_subsBySomeone.count(someone, at) >= config.submissionsADay || _subsByAddress.count(a.address, at) >= config.submissionsPerAddress) throw const _Refused('rate_limited');
    // Counted as they will be once this plugin's open submission is replaced.
    final open = [for (final s in _store.submissions.values) if (s.open && s.plugin != top.id) s];
    if (open.where((s) => s.owner == a.id).length >= config.openPerDeveloper) throw const _Refused('open_limit');
    if (open.where((s) => s.address == a.address).length >= config.openPerAddress) throw const _Refused('open_limit');
    if (!config.needVerified && who == null && open.where((s) => whoOf(s.owner) == null).length >= config.openUnverified) throw const _Refused('open_limit');
    if (open.length >= config.openTotal) throw const _Refused('open_limit');
    // Room: only what isn't on disk already counts, against the developer's share and against the whole store's.
    final mineOnDisk = _blobsOf(a.id);
    final names = {'packages/$sha': package.length, for (final x in taken) 'shots/${x.sha256}': x.size};
    var forDeveloper = 0, forAll = 0;
    for (final e in names.entries) {
      if (!mineOnDisk.contains(e.key)) forDeveloper += e.value;
      if (!_store.blobs.containsKey(e.key)) forAll += e.value;
    }
    if (_bytesOf(a.id) + forDeveloper > config.bytesPerDeveloper) throw const _Refused('developer_full');
    if (_store.bytesInAll + forAll > config.total) throw const _Refused('full');

    // A check stores nothing and counts nothing.
    if (check) return _answer(r, 200, {'ok': true, 'checked': true});

    // The plugin's record and the day's counts are made before the first wait, so nothing that runs meanwhile finds
    // the id free or the room still there.
    final made = plugin == null;
    // Held for [idHeld] from now until its submission is recorded below: a record left with none (the relay stopped or
    // crashed between its writes and its record) is let go by the sweep, never held for good (review, 2026-11-20).
    final p = plugin ?? (_store.plugins[top.id] = MarketPlugin(id: top.id, owner: a.id, developer: top.developer, createdAt: at, updatedAt: at, openUntil: at + idHeld.inMilliseconds));
    _subsBySomeone.add(someone, at);
    _subsByAddress.add(a.address, at);
    // What this request writes that wasn't on disk before, deleted again with the day's counts given back where it is
    // refused after its writes: kept, no submission named them, so no sweep ever found them, they counted against the
    // store's room for good, and the developer lost one of the day's submissions to a request that was refused
    // (review, 2026-11-20). Route 8 is one at a time, so nothing else has taken them up meanwhile.
    final created = <(String, String)>{
      if (!_store.has('packages', sha)) ('packages', sha),
      for (final x in taken)
        if (x.bytes != null && !_store.has('shots', x.sha256)) ('shots', x.sha256),
    };
    Future<void> undo() async {
      _subsBySomeone.drop(someone, at);
      _subsByAddress.drop(a.address, at);
      for (final (kind, name) in created) {
        await _store.deleteBlob(kind, name);
      }
      // The record this call made goes with it: route 8 is one at a time, so nothing else has recorded a submission
      // for it meanwhile. Kept where an earlier developer's closed submissions of a released id were still there, it
      // had no submission and no openUntil, and held the id for good (review, 2026-11-20).
      if (made) _store.plugins.remove(top.id);
    }

    try {
      await _store.writeBlob('packages', sha, package);
      for (final x in taken) {
        if (x.bytes != null) await _store.writeBlob('shots', x.sha256, x.bytes!);
      }
      await debugAfterWrites?.call();
    } catch (_) {
      await undo();
      rethrow;
    }
    // Asked again after the waits: route 16 isn't one at a time with route 8, so the waiting version may have been
    // approved meanwhile. Taken then, an older version would be left waiting under a newer current one, and approving
    // it would list the older (review, 2026-11-20).
    final approvedMeanwhile = p.current;
    if (approvedMeanwhile != null && compareVersions(top.version, approvedMeanwhile.version) <= 0) {
      await undo();
      throw const _Refused('version_not_newer');
    }
    for (final old in [for (final s in _store.submissions.values) if (s.plugin == top.id && s.open) s]) {
      _close(old, 'superseded', 'developer', 'Replaced by ${top.version}.');
      _store.audit(a.id, 'supersede', plugin: top.id, sid: old.sid);
    }
    final sid = _newId(12, _store.submissions.containsKey);
    final s = MarketSubmission(
      sid: sid,
      plugin: top.id,
      version: top.version,
      sha256: sha,
      size: package.length,
      owner: a.id,
      address: a.address,
      list: list,
      submittedAt: at,
      updatedAt: at,
      manifest: top.manifest,
      shots: [for (final x in taken) MarketShot(sha256: x.sha256, mime: 'image/png', size: x.size)],
    );
    if (notes.isNotEmpty) s.note(MarketNote(at: at, by: 'developer', text: notes));
    _store.submissions[sid] = s;
    final d = _store.developers[a.id] ??= MarketDeveloper(id: a.id, firstAt: at);
    d.username = top.developer;
    d.submissions++;
    d.bytes = _bytesOf(a.id);
    p.openUntil = null;
    p.updatedAt = at;
    _changed();
    _store.audit(a.id, 'submit', plugin: top.id, sid: sid, note: top.version);
    _say('${top.id} ${top.version} submitted');
    return _answer(r, 201, {'ok': true, 'submission': _view(s)});
  }

  /// Whether [a] and [b] are the same bytes (nothing secret is compared, so it stops at the first difference).
  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// A submission's owner's, or review's (signed in within the last 8 hours) where [admin].
  MarketSubmission _submissionFor(_Asker a, String sid, {bool admin = true}) {
    final s = _store.submissions[sid];
    if (s == null) throw const _Refused('not_found');
    if (s.owner == a.id) return s;
    if (!admin) throw const _Refused('not_found');
    if (!adminSignedIn(a.id)) throw const _Refused('not_admin');
    return s;
  }

  /// Routes 11 and 12: a submission's package, and its screenshot number n, to its developer or review, approved or
  /// not; never cached.
  Future<void> _submissionPackage(HttpRequest r, _Asker a, String sid) async {
    final s = _submissionFor(a, sid);
    final bytes = await _store.readBlob('packages', s.sha256);
    if (bytes == null) throw const _Refused('not_found');
    return _file(r, bytes, type: 'application/octet-stream', disposition: 'attachment; filename="${s.plugin}-${s.version}.ghostplugin"', public: false);
  }

  // [arg] is `<sid>/<n>` as [_routeOf] made it: 24 hex digits, a slash, one digit.
  Future<void> _submissionShot(HttpRequest r, _Asker a, String arg) async {
    final s = _submissionFor(a, arg.substring(0, 24));
    final n = int.parse(arg.substring(25));
    if (n >= s.shots.length) throw const _Refused('not_found');
    final bytes = await _store.readBlob('shots', s.shots[n].sha256);
    if (bytes == null) throw const _Refused('not_found');
    return _file(r, bytes, type: 'image/png', disposition: 'inline', public: false);
  }

  /// Route 13: its developer takes back a submission still waiting for review. (Review's withdrawal of an approved
  /// version is route 18, [_revoke].)
  Future<void> _withdraw(HttpRequest r, _Asker a, String sid) {
    final s = _submissionFor(a, sid, admin: false);
    if (!s.open) throw const _Refused('wrong_state');
    _close(s, 'withdrawn', 'developer', 'Withdrawn.');
    _changed();
    _store.audit(a.id, 'withdraw', plugin: s.plugin, sid: s.sid);
    return _answer(r, 200, {'ok': true, 'submission': _view(s)});
  }

  /// Route 9: the asker's own newest 100 submissions, their plugins' listings, and whether they are blocked.
  Future<void> _mine(HttpRequest r, _Asker a) => _answer(r, 200, {
        'ok': true,
        'blocked': _store.developers[a.id]?.blocked ?? false,
        'submissions': [for (final s in _store.submissions.values.where((s) => s.owner == a.id).toList().reversed.take(100)) _view(s)],
        'plugins': [for (final p in _store.plugins.values) if (p.owner == a.id) _pluginState(p)],
      });

  /// A submission no longer open: its note, its address dropped (kept only while it is open), and where the plugin has
  /// nothing approved and nothing else waiting, its id held [idHeld] more.
  void _close(MarketSubmission s, String status, String by, String text) {
    final now = _ms();
    s.status = status;
    s.updatedAt = now;
    s.address = null;
    s.note(MarketNote(at: now, by: by, text: text, status: status));
    final p = _store.plugins[s.plugin];
    if (p != null && p.versions.isEmpty && !_hasOpen(p.id)) p.openUntil = now + idHeld.inMilliseconds;
  }

  // --- what is shown --------------------------------------------------------------------------------------------------

  /// Everything its developer may see of a submission: their own words back to them; the app draws its page from the
  /// package.
  Map<String, Object?> _view(MarketSubmission s) {
    final p = _store.plugins[s.plugin];
    final m = s.manifest;
    return {
      'sid': s.sid,
      'plugin': s.plugin,
      'version': s.version,
      'sha256': s.sha256,
      'size': s.size,
      'status': s.status,
      for (final k in const ['name', 'tagline', 'description', 'symbol', 'hue', 'shelf', 'labels', 'permissions', 'links', 'developer', 'support', 'whatsNew', 'minApp']) k: m[k],
      'submittedAt': s.submittedAt,
      'updatedAt': s.updatedAt,
      'notes': [for (final n in s.notes) n.toJson()],
      'shots': [for (final x in s.shots) {'sha256': x.sha256, 'mime': x.mime}],
      'list': s.list,
      'listing': p != null && p.current?.sid == s.sid ? p.listing : null,
      'revoked': s.revoked,
    };
  }

  /// The earlier submissions of [s]'s plugin by its developer, newest first.
  List<MarketSubmission> _earlier(MarketSubmission s) {
    final out = <MarketSubmission>[];
    for (final x in _store.submissions.values) {
      if (identical(x, s)) break;
      if (x.plugin == s.plugin && x.owner == s.owner) out.add(x);
    }
    return out.reversed.toList();
  }

  /// The reviewer's last note on [x] that asked for changes or turned it down.
  static MarketNote? _askedOf(MarketSubmission x) => x.notes.reversed.where((n) => n.by == 'reviewer' && (n.status == 'changes_requested' || n.status == 'rejected')).firstOrNull;

  /// A submission as review sees it: [_view], and whose it is, whether it updates a listed version and what more that
  /// would let it do, and whether review has sent an earlier one back (`again`).
  Map<String, Object?> _row(MarketSubmission s) {
    final current = _store.plugins[s.plugin]?.current;
    final update = current != null && current.sid != s.sid;
    final had = <Object?>{...?(_store.submissions[current?.sid]?.manifest['permissions'] as List?)};
    return {
      ..._view(s),
      'developerId': s.owner,
      'verified': whoOf(s.owner) != null,
      'blocked': _store.developers[s.owner]?.blocked ?? false,
      'isUpdate': update,
      // What this version may do that the listed one can't: a new plugin's are all in What it can do.
      'newPermissions': update ? [for (final x in s.manifest['permissions'] as List) if (!had.contains(x)) x] : const <String>[],
      'again': _earlier(s).any((x) => _askedOf(x) != null),
    };
  }

  /// A plugin's listing as its developer and review are told it: listed or not, by whom it was taken off, and why.
  Map<String, Object?> _pluginState(MarketPlugin p) => {'id': p.id, 'listing': p.listing, 'current': p.current?.version, 'by': p.by, 'note': p.note, 'noteAt': p.noteAt};

  /// A developer as review sees them, whether or not they have submitted anything yet.
  Map<String, Object?> _developerView(String devId) {
    final d = _store.developers[devId];
    return {
      'id': devId,
      'username': d?.username ?? usernameOf?.call(devId),
      'blocked': d?.blocked ?? false,
      'plugins': _store.plugins.values.where((p) => p.owner == devId).length,
      'submissions': d?.submissions ?? 0,
      'firstAt': d?.firstAt,
    };
  }

  // --- review ---------------------------------------------------------------------------------------------------------

  /// Route 14, review's: everything waiting, the 50 most lately decided, and how many are in each state.
  Future<void> _queue(HttpRequest r, _Asker a) {
    _admin(a);
    final all = _store.submissions.values.toList();
    final open = [for (final s in all) if (s.open) s];
    final decided = [for (var i = all.length - 1; i >= 0; i--) if (!all[i].open) all[i]];
    // Newest first, and of two decided at once, the later sent.
    final order = {for (var i = 0; i < decided.length; i++) decided[i].sid: i};
    decided.sort((x, y) => x.updatedAt != y.updatedAt ? y.updatedAt.compareTo(x.updatedAt) : order[x.sid]!.compareTo(order[y.sid]!));
    int count(String status) => all.where((s) => s.status == status).length;
    return _answer(r, 200, {
      'ok': true,
      'open': [for (final s in open) _row(s)],
      'recent': [for (final s in decided.take(50)) _row(s)],
      'counts': {'submitted': count('submitted'), 'in_review': count('in_review'), 'changes_requested': count('changes_requested'), 'reports': _store.reports.values.where((x) => !x.done).length, 'abuse': _store.abuse.values.where((x) => !x.done).length},
    });
  }

  /// Route 15, review's: one submission with all a reviewer compares it against: its package, the listed version's
  /// (`previous`), the last one of the developer's that review sent back, with the note (`asked`), the plugin's
  /// earlier submissions and the developer.
  Future<void> _item(HttpRequest r, _Asker a, String sid) async {
    _admin(a);
    final s = _store.submissions[sid];
    if (s == null) throw const _Refused('not_found');
    final package = await _store.readBlob('packages', s.sha256);
    final current = _store.plugins[s.plugin]?.current;
    Map<String, Object?>? previous;
    if (current != null && current.sid != s.sid) {
      final bytes = await _store.readBlob('packages', current.sha256);
      if (bytes != null) previous = {'version': current.version, 'sha256': current.sha256, 'package': base64Encode(bytes)};
    }
    Map<String, Object?>? asked;
    for (final x in _earlier(s)) {
      final n = _askedOf(x);
      if (n == null || x.swept) continue;
      final bytes = await _store.readBlob('packages', x.sha256);
      if (bytes == null) continue;
      asked = {'sid': x.sid, 'version': x.version, 'sha256': x.sha256, 'package': base64Encode(bytes), 'note': n.text, 'status': n.status};
      break;
    }
    final history = [for (final x in _store.submissions.values) if (x.plugin == s.plugin && x.owner == s.owner && x.sid != s.sid) x].reversed.take(20);
    return _answer(r, 200, {
      'ok': true,
      'submission': _row(s),
      'package': package == null ? null : base64Encode(package),
      'previous': previous,
      'asked': asked,
      'history': [for (final x in history) _view(x)],
      'developer': _developerView(s.owner),
    });
  }

  /// A PackApproval of exactly its fields, or null.
  static Map<String, Object?>? _approvalOf(Object? j) {
    if (j is! Map || j.length != 7) return null;
    final v = j['v'], plugin = j['plugin'], version = j['version'], sha = j['sha256'], key = j['key'], sig = j['sig'], at = j['at'];
    if (v != 1 || plugin is! String || version is! String || sha is! String || key is! String || sig is! String || at is! int) return null;
    return {'v': 1, 'plugin': plugin, 'version': version, 'sha256': sha, 'key': key, 'sig': sig, 'at': at};
  }

  /// A PackRevocation of exactly its fields, or null.
  static Map<String, Object?>? _revocationOf(Object? j) {
    if (j is! Map || j.length != 7) return null;
    final v = j['v'], plugin = j['plugin'], sha = j['sha256'], at = j['at'], why = j['why'], key = j['key'], sig = j['sig'];
    if (v != 1 || plugin is! String || sha is! String || at is! int || why is! String || key is! String || sig is! String) return null;
    return {'v': 1, 'plugin': plugin, 'sha256': sha, 'at': at, 'why': why, 'key': key, 'sig': sig};
  }

  /// A PackRetirement of exactly its fields, or null.
  static Map<String, Object?>? _retirementOf(Object? j) {
    if (j is! Map || j.length != 4) return null;
    final v = j['v'], key = j['key'], at = j['at'], sig = j['sig'];
    if (v != 1 || key is! String || at is! int || sig is! String) return null;
    return {'v': 1, 'key': key, 'at': at, 'sig': sig};
  }

  /// Why [x] can't approve [s], asked by the holder of [key]: its words aren't the submission's, it isn't the asker's
  /// own (the signed-in admin signs their own approvals), the key is retired or not one the store takes, or the
  /// signature doesn't check out.
  String? _approvalProblem(Map<String, Object?>? x, MarketSubmission s, String key) {
    if (x == null || x['plugin'] != s.plugin || x['version'] != s.version || x['sha256'] != s.sha256 || x['key'] != key) return 'bad_approval';
    if (_retiredKeys.contains(key) || (config.reviewKeys.isNotEmpty && !config.reviewKeys.contains(key))) return 'bad_approval';
    if (!_signedBy(key, approvalWords(s.plugin, s.version, s.sha256), x['sig'] as String)) return 'bad_approval';
    return null;
  }

  /// Why [x] can't withdraw a version of [p], asked by the holder of [key]: not_found where its package isn't one of
  /// [p]'s approved versions. Where the store names its review keys, only theirs: every app drops a withdrawal by a key
  /// its build doesn't pin, so another admin's switched nothing off while the store unlisted the plugin, answered 410
  /// for it and kept that one as its withdrawal (review, 2026-11-20). A retired key's still count, as in the app.
  String? _revocationProblem(Map<String, Object?>? x, MarketPlugin p, String key) {
    if (x == null || x['plugin'] != p.id) return 'bad_approval';
    if (!p.versions.any((v) => v.sha256 == x['sha256'])) return 'not_found';
    final why = x['why'] as String;
    if (x['key'] != key || why.isEmpty || why.length > whyMost || !packTextOk(why)) return 'bad_approval';
    if (config.reviewKeys.isNotEmpty && !config.reviewKeys.contains(key)) return 'bad_approval';
    if (!_signedBy(key, revocationWords(p.id, x['sha256'] as String, x['at'] as int, why), x['sig'] as String)) return 'bad_approval';
    return null;
  }

  /// Whether route 3's list with [revocations] and [retirements] added (those it doesn't keep already) is still one every
  /// app reads whole: within [withdrawalsMost] bytes as served, [revocationsMost] withdrawals and [retirementsMost]
  /// retirements. An app refused a longer one all at once and took nothing from it, so withdrawals silently stopped
  /// reaching devices (review, 2026-11-20).
  bool _withdrawalsFit({List<Map<String, Object?>> revocations = const [], List<Map<String, Object?>> retirements = const []}) {
    final revoked = [..._store.revoked, for (final x in revocations) if (!_store.revoked.any((e) => e['sha256'] == x['sha256'] && e['key'] == x['key'])) x];
    final retired = [..._store.retired, for (final x in retirements) if (!_store.retired.any((e) => e['key'] == x['key'])) x];
    if (revoked.length > revocationsMost || retired.length > retirementsMost) return false;
    final at = [for (final x in [...revoked, ...retired]) x['at'] as int].fold(0, max);
    return utf8.encode(jsonEncode({'ok': true, 'v': 1, 'at': at, 'revoked': revoked, 'retired': retired})).length <= withdrawalsMost;
  }

  /// Withdraws one approved package of [p], kept once by its SHA-256 and the key that signed it: its submission says so,
  /// the catalog drops it where it was the current version (unlisted, by review), and its package answers 410 from now
  /// on. Kept once a key, not once a package: a withdrawal by a key some build doesn't pin, kept first, left the pinned
  /// key's own withdrawal of the same version answered 200 and never kept (review, 2026-11-20).
  Map<String, Object?> _withdrawVersion(MarketPlugin p, Map<String, Object?> x, String by) {
    final sha = x['sha256'] as String;
    final had = _store.revoked.where((e) => e['sha256'] == sha && e['key'] == x['key']).firstOrNull;
    if (had != null) return had;
    _store.revoked.add(x);
    String? sid;
    for (final s in _store.submissions.values) {
      if (s.plugin == p.id && s.sha256 == sha && s.status == 'approved') {
        s.revoked = {'at': x['at'], 'why': x['why']};
        sid = s.sid;
      }
    }
    if (p.current?.sha256 == sha) {
      p.listing = 'unlisted';
      p.by = 'admin';
    }
    p.updatedAt = _ms();
    _store.audit(by, 'revoke', plugin: p.id, sid: sid, note: x['why'] as String);
    return x;
  }

  /// Route 16, review's decision on a submission: `start` (in review), `changes` or `reject` (each with a note), or
  /// `approve`, which carries the reviewer's signed approval and may withdraw up to five earlier versions in the same
  /// step, and asks for a sign-in within [freshAdmin].
  Future<void> _decide(HttpRequest r, _Asker a, String sid) {
    _admin(a);
    final j = _object(a.body);
    final decision = j['decision'], note = j['note'], approval = j['approval'], revokes = j['revokes'];
    final shaped = j.keys.every(const {'decision', 'note', 'approval', 'revokes'}.contains) &&
        decision is String &&
        const {'start', 'approve', 'changes', 'reject'}.contains(decision) &&
        (!j.containsKey('note') || (note is String && note.isNotEmpty && note.length <= decisionNoteMost && packTextOk(note, newlines: true))) &&
        ((decision != 'changes' && decision != 'reject') || note != null) &&
        (decision == 'approve') == j.containsKey('approval') &&
        (!j.containsKey('revokes') || (decision == 'approve' && revokes is List && revokes.length <= 5));
    if (!shaped) throw const _Refused('bad_request');
    if (decision == 'approve') _admin(a, fresh: true);
    final s = _store.submissions[sid];
    final p = s == null ? null : _store.plugins[s.plugin];
    if (s == null || p == null) throw const _Refused('not_found');
    final words = note as String?;
    switch (decision) {
      case 'start':
        if (s.status != 'submitted') throw const _Refused('wrong_state');
        _review(s, 'in_review', words ?? 'In review.');
      case 'changes':
        if (s.status != 'submitted' && s.status != 'in_review') throw const _Refused('wrong_state');
        _review(s, 'changes_requested', words!);
      case 'reject':
        if (!s.open) throw const _Refused('wrong_state');
        _close(s, 'rejected', 'reviewer', words!);
      case 'approve':
        if (s.status != 'submitted' && s.status != 'in_review') throw const _Refused('wrong_state');
        // Never a version at or below the one listed: the catalog only ever moves forward (C.7 step 9).
        final listed = p.current;
        if (listed != null && compareVersions(s.version, listed.version) <= 0) throw const _Refused('version_not_newer');
        final x = _approvalOf(approval);
        final problem = _approvalProblem(x, s, a.key);
        if (problem != null) throw _Refused(problem);
        // Earlier versions withdrawn in the same step, each checked as a withdrawal by itself is, all before any is done.
        final withdrawals = [for (final e in (revokes as List?) ?? const []) _revocationOf(e)];
        for (final w in withdrawals) {
          final why = _revocationProblem(w, p, a.key);
          if (why != null) throw _Refused(why);
        }
        if (!_withdrawalsFit(revocations: [for (final w in withdrawals) w!])) throw const _Refused('withdrawals_full');
        _approve(s, p, x!, words);
        for (final w in withdrawals) {
          _withdrawVersion(p, w!, a.id);
        }
    }
    _changed();
    _store.audit(a.id, decision, plugin: s.plugin, sid: s.sid, note: words);
    _say('${s.plugin} ${s.version}: $decision');
    return _answer(r, 200, {'ok': true, 'submission': _row(s)});
  }

  /// A decision that leaves it open: in review, or changes asked for.
  void _review(MarketSubmission s, String status, String text) {
    final now = _ms();
    s.status = status;
    s.updatedAt = now;
    s.note(MarketNote(at: now, by: 'reviewer', text: text, status: status));
  }

  /// [s] approved: the plugin's current version, listed unless it was sent to be listed later or its owner had taken it
  /// off, when it stays (or becomes) unlisted by its owner. An earlier current version stays downloadable for whoever
  /// has it, unless the same step withdraws it.
  void _approve(MarketSubmission s, MarketPlugin p, Map<String, Object?> approval, String? note) {
    final now = _ms();
    p.current = MarketCurrent(version: s.version, sha256: s.sha256, size: s.size, sid: s.sid, approval: approval, approvedAt: now);
    p.versions.add(MarketVersion(version: s.version, sha256: s.sha256, size: s.size, sid: s.sid, approvedAt: now, key: approval['key'] as String));
    if (s.list == 'later' || (p.listing == 'unlisted' && p.by == 'owner')) {
      p.listing = 'unlisted';
      p.by = 'owner';
    } else {
      if (p.listing != 'listed') p.listedAt = now;
      p.listing = 'listed';
      p.by = null;
    }
    p.openUntil = null;
    p.updatedAt = now;
    _close(s, 'approved', 'reviewer', note ?? 'Approved.');
  }

  /// Route 17: review either way; its owner may take it off at any time and list it again only where they took it off.
  Future<void> _listing(HttpRequest r, _Asker a, String id) {
    final j = _object(a.body);
    final listed = j['listed'], note = j['note'];
    final shaped = j.keys.every(const {'listed', 'note'}.contains) && listed is bool && (!j.containsKey('note') || (note is String && note.isNotEmpty && note.length <= listingNoteMost && packTextOk(note, newlines: true)));
    if (!shaped) throw const _Refused('bad_request');
    final p = _store.plugins[id];
    if (p == null) throw const _Refused('not_found');
    final owner = p.owner == a.id;
    final admin = adminSignedIn(a.id, within: freshAdmin);
    if (!owner && !admin) throw const _Refused('not_admin');
    final current = p.current;
    if (current == null) throw const _Refused('wrong_state');
    final now = _ms();
    final on = listed == true;
    if (on) {
      if (_revokedShas.contains(current.sha256)) throw const _Refused('wrong_state');
      if (!admin && p.listing == 'unlisted' && p.by == 'admin') throw const _Refused('admin_unlisted');
      if (!admin && (_store.developers[a.id]?.blocked ?? false)) throw const _Refused('blocked');
      if (p.listing != 'listed') p.listedAt = now;
      p.listing = 'listed';
      p.by = null;
    } else if (!(p.listing == 'unlisted' && p.by == 'admin' && !admin)) {
      // Taken off by review, it stays review's to list again, whatever its owner asks meanwhile.
      p.listing = 'unlisted';
      p.by = owner ? 'owner' : 'admin';
    }
    if (note is String) {
      p.note = note;
      p.noteAt = now;
    }
    p.updatedAt = now;
    _changed();
    _store.audit(a.id, on ? 'list' : 'unlist', plugin: id, note: '${owner ? 'owner' : 'admin'}${note is String ? ': $note' : ''}');
    return _answer(r, 200, {'ok': true, 'plugin': _pluginState(p)});
  }

  /// Route 18, review's: withdraws one approved version of a plugin, by a withdrawal the reviewer signed.
  Future<void> _revoke(HttpRequest r, _Asker a, String id) {
    _admin(a, fresh: true);
    final x = _revocationOf(_object(a.body));
    final p = _store.plugins[id];
    if (p == null) throw const _Refused('not_found');
    final problem = _revocationProblem(x, p, a.key);
    if (problem != null) throw _Refused(problem);
    if (!_withdrawalsFit(revocations: [x!])) throw const _Refused('withdrawals_full');
    final kept = _withdrawVersion(p, x, a.id);
    _changed();
    return _answer(r, 200, {'ok': true, 'revoked': kept, 'plugin': _pluginState(p)});
  }

  /// Route 21, review's: blocks a developer from submitting, or lets them again; with `unlist`, takes their listed
  /// plugins off as well. The note is kept on the developer and on each of their plugins.
  Future<void> _block(HttpRequest r, _Asker a, String devId) {
    _admin(a, fresh: true);
    final j = _object(a.body);
    final blocked = j['blocked'], note = j['note'], unlist = j['unlist'];
    final shaped = j.keys.every(const {'blocked', 'note', 'unlist'}.contains) &&
        blocked is bool &&
        (!j.containsKey('note') || (note is String && note.isNotEmpty && note.length <= listingNoteMost && packTextOk(note, newlines: true))) &&
        (!j.containsKey('unlist') || unlist is bool);
    if (!shaped) throw const _Refused('bad_request');
    final now = _ms();
    final d = _store.developers[devId] ??= MarketDeveloper(id: devId, username: usernameOf?.call(devId), firstAt: now);
    d.blocked = blocked == true;
    if (note is String) d.blockedNote = note;
    for (final p in _store.plugins.values.where((p) => p.owner == devId)) {
      if (unlist == true && p.listing == 'listed') {
        p.listing = 'unlisted';
        p.by = 'admin';
        _store.audit(a.id, 'unlist', plugin: p.id, note: 'admin: blocked');
      }
      if (note is String) {
        p.note = note;
        p.noteAt = now;
      }
      p.updatedAt = now;
    }
    _changed();
    _store.audit(a.id, d.blocked ? 'block' : 'unblock', note: '$devId${note is String ? ': $note' : ''}');
    return _answer(r, 200, {'ok': true, 'developer': _developerView(devId)});
  }

  /// Route 22, from anyone: a review key's own retirement, taken only for a key that has signed something the market
  /// holds (so the list can't be filled with strangers' keys), ten an hour from one address.
  Future<void> _retire(HttpRequest r) async {
    final now = _ms();
    if (!_retires.take(Files.addressOf(r), 10, now)) throw const _Refused('rate_limited');
    if (r.contentLength < 0) throw const _Refused('bad_request');
    if (r.contentLength > retireMost) throw const _Refused('too_large');
    final x = _retirementOf(_object(await _readBody(r, r.contentLength)));
    if (x == null) throw const _Refused('bad_request');
    final key = x['key'] as String;
    if (!_signers.contains(key)) throw const _Refused('not_found');
    final had = _store.retired.where((e) => e['key'] == key).firstOrNull;
    if (had != null) return _answer(r, 200, {'ok': true, 'retired': had});
    if (!_mayVerify(now)) throw const _Refused('busy');
    if (!_signedBy(key, retirementWords(key), x['sig'] as String)) throw const _Refused('bad_signature');
    if (!_withdrawalsFit(retirements: [x])) throw const _Refused('withdrawals_full');
    _store.retired.add(x);
    _changed();
    _store.audit(FilesRoster.idOf(base64Decode(key)), 'retire', note: key);
    _say('a review key retired');
    return _answer(r, 200, {'ok': true, 'retired': x});
  }

  // --- what changes with each change ----------------------------------------------------------------------------------

  /// Called after every change to the store: the served lists are made again and state.json is saved soon.
  void _changed() {
    _rebuild();
    _store.changed();
  }

  /// The catalog's and the withdrawals' bytes and ETags, and what the public routes look up, made again after a change.
  void _rebuild() {
    _revokedShas = {for (final x in _store.revoked) x['sha256'] as String};
    _retiredKeys = {for (final x in _store.retired) x['key'] as String};
    _approved = {
      for (final p in _store.plugins.values)
        for (final v in p.versions) v.sha256: (p.id, v.version),
    };
    _signers = {
      for (final p in _store.plugins.values)
        for (final v in p.versions)
          if (v.key != null) v.key!,
      for (final x in _store.revoked) x['key'] as String,
    };
    final listed = [for (final p in _store.plugins.values) if (p.listing == 'listed' && p.current != null && !_revokedShas.contains(p.current!.sha256)) p];
    _listedShots = {
      for (final p in listed)
        for (final x in _store.submissions[p.current!.sid]?.shots ?? const <MarketShot>[]) x.sha256,
    };
    // Only what an approval covers, or what nobody draws: the app fetches each package and draws everything from it.
    final entries = [
      for (final p in listed)
        {
          'id': p.id,
          'version': p.current!.version,
          'sha256': p.current!.sha256,
          'size': p.current!.size,
          'approval': p.current!.approval,
          'listedAt': p.listedAt ?? p.current!.approvedAt,
          'updatedAt': p.current!.approvedAt,
        },
    ]..sort((x, y) => x['updatedAt'] != y['updatedAt'] ? (y['updatedAt'] as int).compareTo(x['updatedAt'] as int) : (x['id'] as String).compareTo(y['id'] as String));
    final words = jsonEncode(entries.take(2000).toList());
    if (words != _catalogWords) {
      // Kept from before a restart where nothing listed changed, so the ETag an app holds still matches.
      if (_catalogWords != null) _store.listingAt = _ms();
      _catalogWords = words;
      _catalog = utf8.encode('{"ok":true,"v":1,"at":${_store.listingAt},"plugins":$words}');
      _catalogTag = '"${hexOf(sha256(_catalog)).substring(0, 16)}"';
    }
    final withdrawals = jsonEncode({'revoked': _store.revoked, 'retired': _store.retired});
    if (withdrawals != _withdrawalsWords) {
      _withdrawalsWords = withdrawals;
      final at = [for (final x in [..._store.revoked, ..._store.retired]) x['at'] as int].fold(0, max);
      _withdrawals = utf8.encode(jsonEncode({'ok': true, 'v': 1, 'at': at, 'revoked': _store.revoked, 'retired': _store.retired}));
      _withdrawalsTag = '"${hexOf(sha256(_withdrawals)).substring(0, 16)}"';
    }
  }

  /// Every minute: drops the replays and counts that have run out, so memory holds only what still limits someone.
  void _prune() {
    final now = _ms();
    _pruneReplays(now);
    for (final w in [_signedByAddress, _reads, _listReads]) {
      w.prune(now);
    }
    for (final w in [_signedByKey, _retires, _subsBySomeone, _subsByAddress, _reportsByKey, _reportsByKeyPlugin, _reportsByAddress, _reportsBySomeone, _reportsUnknown]) {
      w.prune(now);
    }
  }

  // --- the daily sweep ------------------------------------------------------------------------------------------------

  /// Deletes closed submissions' blobs that nothing uses once they're 30 days old, and lets go of ids with nothing
  /// approved 30 days after their last submission closed (market_store.dart). In route 8's chain, so it never deletes a
  /// screenshot a submission is keeping.
  Future<void> sweep() => _oneAtATime(() async {
        final (:swept, :released, :orphaned) = await _store.sweep(_now());
        for (final s in swept) {
          _store.audit('relay', 'sweep', plugin: s.plugin, sid: s.sid);
        }
        for (final id in released) {
          _store.audit('relay', 'release', plugin: id);
        }
        if (swept.isEmpty && released.isEmpty && orphaned == 0) return;
        for (final d in _store.developers.values) {
          d.bytes = _bytesOf(d.id);
        }
        _changed();
        _say('swept ${swept.length}, released ${released.length}');
      });

  /// The sweep as the timer runs it: a failure is a line on stderr, never an unhandled error.
  Future<void> _sweepQuietly() async {
    try {
      await sweep();
    } catch (e) {
      stderr.writeln('market: the sweep stopped: $e');
    }
  }
}

/// A signed request that checked out, with its body read and held to its hash.
class _Asker {
  _Asker({required this.id, required this.key, required this.body, required this.address, required this.release});

  /// The hub id of its key (FilesRoster.idOf), and the key as an approval names it (base64 of its 33 bytes).
  final String id, key;
  final Uint8List body;
  final String address;

  /// Gives back the slot its body holds, where it is a large one: called once its route is done with the body.
  final void Function() release;
}

/// A request refused with one of [Market.errors].
class _Refused implements Exception {
  const _Refused(this.code, {this.issues});
  final String code;
  final List<PackIssue>? issues;
}

/// Counts by name (an address) in fixed windows: at most [most] names, the longest unseen going first, so a flood of
/// fresh addresses can't fill the relay's memory.
class _Windows {
  _Windows(this.per);
  final Duration per;
  static const most = 50000;
  final LinkedHashMap<String, (int, int)> _counts = LinkedHashMap();

  /// Whether [name] may have one more of [limit] in this window: counted where it may.
  bool take(String name, int limit, int now) {
    final start = now - now % per.inMilliseconds;
    final had = _counts.remove(name);
    final n = had != null && had.$1 == start ? had.$2 : 0;
    _counts[name] = (start, n < limit ? n + 1 : n);
    while (_counts.length > most) {
      _counts.remove(_counts.keys.first);
    }
    return n < limit;
  }

  void prune(int now) {
    final start = now - now % per.inMilliseconds;
    _counts.removeWhere((_, v) => v.$1 < start);
  }
}

/// Times by name within a sliding window, for counts small enough to keep each one: a key's hour, a day's submissions
/// and reports.
class _Recent {
  _Recent(this.per);
  final Duration per;
  static const most = 100000;
  final LinkedHashMap<String, List<int>> _times = LinkedHashMap();

  int count(String name, int now) {
    final list = _times[name];
    if (list == null) return 0;
    list.removeWhere((t) => now - t >= per.inMilliseconds);
    return list.length;
  }

  void add(String name, int now) {
    final list = _times.remove(name) ?? <int>[];
    _times[name] = list..add(now);
    while (_times.length > most) {
      _times.remove(_times.keys.first);
    }
  }

  /// Takes back one count of [name] made at [at]: a request refused after it was counted.
  void drop(String name, int at) {
    final list = _times[name];
    if (list == null) return;
    list.remove(at);
    if (list.isEmpty) _times.remove(name);
  }

  /// Whether [name] may have one more of [limit] within the window: counted where it may.
  bool take(String name, int limit, int now) {
    if (count(name, now) >= limit) return false;
    add(name, now);
    return true;
  }

  void prune(int now) => _times.removeWhere((_, list) {
        list.removeWhere((t) => now - t >= per.inMilliseconds);
        return list.isEmpty;
      });
}
