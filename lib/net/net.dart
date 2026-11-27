import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../app_state.dart';
import '../friends/buddies.dart' show Buddy;
import '../me/me.dart' show Me;
import '../platform_info.dart';
import '../relay_host/address.dart';
import '../relay_host/direct_link.dart';
import '../relay_host/hosting.dart';
import '../relay_host/relay_host.dart';
import '../sms.dart';
import 'carrier.dart';
import 'crypto.dart';
import 'forward_secrecy.dart';
import 'homes.dart';
import 'hub_carrier.dart';
import '../invites/link_relay.dart';
import 'hub_link.dart';
import 'kept_files.dart';
import 'lan/lan_carrier.dart';
import 'lan/lan_ground.dart';
import 'lan/lan_wire.dart';
import 'ledger.dart';
import 'p2p/node.dart';
import 'p2p/node_factory.dart' show letP2pNodeGo;
import 'p2p/p2p.dart';
import 'p2p/p2p_carrier.dart' show P2pCarrier;
import 'packet.dart';
import 'relay_choice.dart';
import 'routes_kept.dart';
import 'sms_carrier.dart';
import 'switchboard.dart';

/// Something the routes did, for Settings › Network to show: what, to or from whom, by which route, and when.
class NetEvent {
  NetEvent(this.words, {this.via}) : at = DateTime.now();
  final String words;
  final String? via;
  final DateTime at;
}

/// The app's routes as the app holds them (Matt, 2026-11-14: "implement a full relay system for the app that's
/// replacable and swappable", "multiple sources to feed data to eachother from wifi locally, p2p, internet, sms,
/// etc"): the switchboard (switchboard.dart), the routes this phone has (the relay server's hub and SMS data texts
/// now; the local network and a peer-to-peer one are made room for), and the people they reach.
///
/// The people are the ones encryption is on with: exchanging keys by text is what introduces two phones, and the
/// phone's own key pair is who it is (android/.../Net.kt). Nothing dials out until there is someone to reach and
/// the person has not switched the network off (Settings › Network).
///
/// What the person chooses is kept with their other choices: `net_on`, `net_hub` (the relay server's address),
/// `net_off` (the routes switched off, by name), `net_direct` (Direct switched on or off: [directName]).
///
/// **The direct route** (lib/net/p2p; docs/OPEN_NETWORK.md, section 2) is offered where the build has its core
/// ([p2pNode]) and is there only while the person has switched Direct on ([directOn]): after the relay's hub in the
/// order, linking only with this account's own devices and with friends ([friends]), and kept in step with the people,
/// how the person chose to be shown, the app being put away and coming back, and the relay in use. Until it is
/// switched on nothing of it is made or run, the core least of all: no library opened, no node, no ledger.
class Net extends ChangeNotifier implements PeerBook {
  Net._();
  static final Net instance = Net._();

  /// Makes this device's node on the direct network: the core's own (makeP2pNode, lib/net/p2p/node_factory.dart), set
  /// where the app starts on a platform whose builds carry the core (Android, the Mac, Windows, Linux). Asked for a
  /// node only once the person has switched Direct on ([directOn]), and once for as long as the app runs: until then
  /// nothing of the core runs, not so much as its library being opened (docs/OPEN_NETWORK.md, section 2: "a person who
  /// never switches Direct on runs none of it"). Null: there is no core here, no direct route is ever made, and
  /// Settings › Routes shows no Direct. Answering null where Direct is switched on: the build left its core out, and
  /// Settings › Routes says so ([directProblem]).
  static P2pNode? Function()? p2pNode;

  /// Whether Direct is on where the person has not chosen ([directName]): off in the first release that carries the
  /// core, so each person switches it on themselves; the default once Matt has used it, when this turns true and
  /// whoever switched it off stays off.
  static const directByDefault = false;

  /// The person's choice of Direct, kept with their other choices: 'on' or 'off', nothing where they have not chosen.
  /// Direct is the one route that starts off, so its choice is its own, never in `net_off`, which lists the routes
  /// switched off of those that start on: someone who never chose is told apart from someone who switched it off, and
  /// a later default ([directByDefault]) reaches the first and not the second. Seeding `net_off` with Direct instead
  /// would have made the two one.
  static const directName = 'net_direct';

  /// Whether this build offers Direct at all: it was given a way to make the core's node ([p2pNode]).
  bool get directOffered => p2pNode != null;

  /// Whether Direct is switched on: the person's choice ([directName]), or where they have not chosen,
  /// [directByDefault]. Never in a build that offers no Direct.
  bool get directOn {
    if (p2pNode == null) return false;
    final chosen = _app?.choice(directName, '') ?? '';
    return chosen == 'on' || (chosen != 'off' && directByDefault);
  }

  /// The relay server the app is given: ours. Anyone can run their own (relay/README.md) and put its address here.
  static const defaultHub = 'wss://gogho.st/hub';

  /// The relay server an install uses where the person has chosen none: ours ([defaultHub]) on every phone and
  /// computer. A page in a browser may speak only to the address it came from, so there it is that address's own hub,
  /// put here before the routes start (lib/web/app.dart).
  static String homeHub = defaultHub;

  AppState? _app;
  Switchboard? _board;
  HubCarrier? _hub;
  SmsCarrier? _sms;
  final Map<String, Peer> _peers = {};
  final List<StreamSubscription<dynamic>> _subs = [];

  /// This phone's name to the others; null until the phone has said.
  String? id;

  /// Why the routes could not be set up, in words; null when they were.
  String? error;

  /// Why this build's direct route is not there though it has a core, in words for Settings › Routes; null where it is
  /// there, or where the build has none.
  String? directProblem;

  /// The last things the routes did, newest first.
  final List<NetEvent> recent = [];

  Switchboard? get board => _board;
  HubCarrier? get hub => _hub;

  /// This account's home record and what the relay is told of where friends live (homes.dart; docs/OPEN_NETWORK.md,
  /// section 4): what lets someone on another relay be a friend. Null until the routes are set up, and where the
  /// routes are a test's own.
  Homes? get homes => _homes;
  Homes? _homes;

  /// Something small kept with the app's choices, and read back, without drawing anything again.
  String recall(String key) => _app?.choice(key, '') ?? '';
  void remember(String key, String value) => _app?.keep(key, value);

  // --- the direct route (lib/net/p2p) ---------------------------------------------------------------------------------

  P2p? _p2p;

  /// The app's hold on the direct network; null where this build has no core, Direct is switched off, or the routes
  /// are not set up.
  P2p? get p2p => _p2p;

  /// The node [p2pNode] made, kept for as long as these routes run (and [_nodeBy], what made it, and [_nodeOf], whose
  /// it is): switching Direct off stops it, and switching it on again starts the same one, so the core never holds one
  /// for each time. Never another account's: the routes going (sign-out) let it go, and so does another account, so
  /// that nothing of the core (its port least of all) links one account on this device with the next.
  P2pNode? _node;
  P2pNode? Function()? _nodeBy;
  String? _nodeOf;

  /// Who this account is to the routes, and which of its devices this is, as [start] found them: what a direct
  /// network made later, when Direct is switched on, is made with.
  NetSigner? _signer;
  String? _device;

  /// Switching Direct on and off, one change after another ([setDirect]).
  Future<void> _directTurn = Future.value();

  /// Goes up whenever what Settings › Routes shows of the direct route changes: the devices known, the links, the
  /// link helpers, what the ledger's comparisons found. Apart from the routes' own changes, which friends' unanswered
  /// words are sent again on.
  final ValueNotifier<int> direct = ValueNotifier(0);

  /// Heard from the direct network, the ledger and its check: [direct] goes up.
  void _directChanged() => direct.value++;

  // --- the local network route (lib/net/lan; GMFB-24) -----------------------------------------------------------------

  /// What the local network route stands on (lan_wire.dart): sockets on a phone or a computer, nothing in a browser or
  /// on an iPhone, and nothing under a test unless it hands in a network of its own (it would open ports on the
  /// machine the tests run on).
  static LanGround? Function() lanGround = defaultLanGround;
  static LanGround? defaultLanGround() => PlatformInfo.environment.containsKey('FLUTTER_TEST') ? null : makeLanGround();

  /// Whether the local network route is on where the person has not chosen ([lanName]): off in the first release that
  /// carries it, as Direct was, so each person switches it on themselves (it makes the Mac and Windows ask whether the
  /// app may use the local network).
  static const lanByDefault = false;

  /// The person's choice of the local network route: 'on' or 'off', nothing where they have not chosen. Its own, never
  /// in `net_off`, for the reason Direct's is ([directName]).
  static const lanName = 'net_lan';

  LanGround? _lanGround;
  LanCarrier? _lan;

  /// The local network route; null where this build has none (a browser, an iPhone), or the routes are not set up.
  LanCarrier? get lan => _lan;

  /// Whether the local network route is switched on: the person's choice, or where they have not chosen,
  /// [lanByDefault]. Never in a build that has none.
  bool get lanOn {
    if (_lanGround == null) return false;
    final chosen = _app?.choice(lanName, '') ?? '';
    return chosen == 'on' || (chosen != 'off' && lanByDefault);
  }

  /// Whom the local network route says it is here to and links with: friends, and this account's own other devices
  /// (as one peer, by this account's name and its own key). Never the other members of a group.
  List<Peer> _lanPeople() {
    final me = id, mine = _mineKey;
    return [...friends, if (me != null && mine != null) Peer(id: me, key: mine)];
  }

  /// The accounts the local network route was linked to when it last said anything changed, and when the routes were
  /// last said to have changed for it.
  Set<String> _lanAccounts = {};
  DateTime? _lanSaid;
  Timer? _lanSayLater;

  /// The least time between two sayings that the routes changed for the local network's links (a test says another).
  @visibleForTesting
  static Duration lanSayEvery = const Duration(seconds: 20);

  /// Who is seen or linked on the local network changed: Settings › Routes draws it again. Where an account is linked
  /// that was not before, the routes are said to have changed, so what friends were sent and have not answered goes
  /// again (Friends) and what a group's members are owed goes (Groups): but no oftener than [lanSayEvery], and never
  /// for a link lost. One made sooner after the last is said when that time is up, not lost. Every change of the count
  /// said so before, and each time Friends sent again everything unanswered, which whoever could make a link come and
  /// go could have it do at will (found in review, 2026-11-26).
  void _lanChanged() {
    direct.value++;
    final now = _lan?.linkedAccounts ?? const <String>{};
    final someoneNew = now.any((a) => !_lanAccounts.contains(a));
    _lanAccounts = now;
    if (!someoneNew || _lanSayLater != null) return;
    final at = DateTime.now(), last = _lanSaid;
    final wait = last == null ? Duration.zero : lanSayEvery - at.difference(last);
    if (wait > Duration.zero) {
      _lanSayLater = Timer(wait, () {
        _lanSayLater = null;
        _lanSaid = DateTime.now();
        notifyListeners();
      });
      return;
    }
    _lanSaid = at;
    notifyListeners();
  }

  /// Switches the local network route on or off (Settings › Routes), kept as the person's choice ([lanName]). On: who
  /// is a friend is read (only this route and Direct ask), and the route started where there is anyone to reach. Off:
  /// every link closed and nothing said or heard on the network.
  Future<void> setLan(bool on) async {
    if (_lanGround == null) return;
    _app?.set(lanName, on ? 'on' : 'off');
    final board = _board;
    if (board == null) return notifyListeners();
    if (on) {
      board.off.remove(LanCarrier.routeId);
      try {
        await _readPeers();
      } catch (_) {}
      if (!identical(board, _board)) return;
      _lan?.refresh();
    } else {
      board.off.add(LanCarrier.routeId);
      await board.setOn(LanCarrier.routeId, false);
    }
    if (!identical(board, _board)) return;
    await _apply();
    notifyListeners();
  }

  /// Goes up whenever the route that last carried something to or from someone changes (Switchboard.used): Settings ›
  /// Routes draws which route each person is on from it.
  final ValueNotifier<int> routesUsed = ValueNotifier(0);

  void _routesUsedChanged() {
    routesUsed.value++;
    final board = _board;
    if (board != null) _routesKept?.changed(() => board.used);
  }

  /// Where which route each person was last on is kept from one run to the next (routes_kept.dart): a file of its own,
  /// out of any backup; under a test, memory; null where there is nowhere (a browser), and then nothing is kept.
  static FsStore? Function() routesStore = defaultRoutesStore;
  static FsStore? defaultRoutesStore() => PlatformInfo.environment.containsKey('FLUTTER_TEST') ? MemoryFsStore() : routesFiles();

  RoutesKept? _routesKept;

  /// Reads what was kept of which route each person was on, for this account, into [board], and keeps what it sees
  /// from now on. Whatever goes wrong there costs only that.
  void _keepRoutes(Switchboard board, String me) {
    try {
      final store = routesStore();
      if (store == null) return;
      final kept = _routesKept = RoutesKept(store: store, me: me);
      unawaited(kept.read().then((was) {
        if (identical(board, _board) && identical(kept, _routesKept)) board.seedUsed(was);
      }).catchError((Object _) {}));
    } catch (_) {
      _routesKept = null;
    }
  }

  /// Deletes which route each person was on, here and where it is kept: signing out.
  Future<void> forgetRoutesUsed() async {
    final kept = _routesKept;
    _routesKept = null;
    _board?.clearUsed();
    if (kept != null) return kept.wipe();
    final store = routesStore();
    if (store != null) await RoutesKept.forget(store);
  }

  // --- checking the relay (lib/net/ledger.dart; docs/OPEN_NETWORK.md, section 3) -------------------------------------

  Ledger? _ledger;
  LedgerCheck? _check;

  /// What went to each friend and came from them, and what comparing it over direct links found of the relay; null
  /// where this build has no direct route (nothing could compare it), or the routes are not set up.
  Ledger? get ledger => _ledger;
  LedgerCheck? get check => _check;

  /// Who else holds what was sent and is unanswered, to send it again where a friend's device says it never came
  /// (Friends' list: lib/friends/friends.dart); kept here, so a check made later is given them too.
  final List<Envelope? Function(String peer, String id)> _holders = [];

  /// Adds one of them, once; the check running now is given it too.
  void addHolder(Envelope? Function(String peer, String id) holder) {
    if (_holders.contains(holder)) return;
    _holders.add(holder);
    _check?.holders.add(holder);
  }

  /// Those of [people] who are friends: whom the direct route links with, and tells where this device is. Never
  /// someone who has only asked or been asked, nor the other members of a group.
  List<Peer> get friends => [for (final p in _peers.values) if (_friendIds.contains(p.id)) p];
  Set<String> _friendIds = {};

  /// The relay's route whose link helpers are listened for ([_followHelpers]).
  HubCarrier? _helpersOf;

  /// The relay named its link helpers as the app signed in to it ([HubCarrier.helpers]).
  void _helpersSaid() {
    final hub = _helpersOf;
    if (hub == null) return;
    // A relay hosted from an app is reached over Direct by the helpers in use now: one that names none (its keeper's own
    // relay named none) doesn't take them away, or the node would start again without them and its link to the relay
    // would go with it, for good.
    if (isGhostRelay(hub.url) && hub.helpers.value.isEmpty) return;
    _p2p?.setHelpers(hub.helpers.value);
  }

  /// Listens for the link helpers [hub] names, in place of the route listened to before.
  void _followHelpers(HubCarrier? hub) {
    _helpersOf?.helpers.removeListener(_helpersSaid);
    _helpersOf = hub;
    hub?.helpers.addListener(_helpersSaid);
  }

  Timer? _p2pTimer;

  /// Reads what the direct network keeps, now and every half minute until it can be read (a secret store that is
  /// locked, as [_fsAgain] waits out).
  void _loadDirect(P2p p2p) {
    unawaited(p2p.tryLoad().then((ok) {
      if (ok || !identical(p2p, _p2p)) return;
      _p2pTimer?.cancel();
      _p2pTimer = Timer.periodic(const Duration(seconds: 30), (t) async {
        if (!identical(p2p, _p2p) || p2p.loaded || await p2p.tryLoad()) t.cancel();
      });
    }));
  }

  Map<String, Object?>? _push;

  // --- a relay hosted from this device, and others' (lib/relay_host; docs/OPEN_NETWORK.md, section 5) ---------------

  RelayHosting? _host;

  /// Makes this device's relay host as the routes start (lib/relay_host/relay_host.dart): the platform's own, which is
  /// none on an iPhone or in a browser; a test hands in one of its own, as it does a node ([p2pNode]).
  static RelayHosting? Function() relayHostMaker = makeRelayHost;

  /// The relay this device hosts, where it can host one (the Mac, Windows, Linux, Android); null on an iPhone, in a
  /// browser, and before the routes are set up. Off unless the person switches it on (Settings › Routes).
  RelayHosting? get relayHost => _host;

  /// The name of the relay this device hosts, where it has one: what Settings › Routes calls "the relay on this device".
  String? get hostedHere => _host?.relayId;

  /// The pass phrase given for the relay this app uses, where it asked one (kept where the install keeps its keys,
  /// `relay_pass`, with the relay's address: a phrase is for one relay alone).
  ({String url, String pass})? _joinPass;
  static const joinPassName = 'relay_pass';

  Future<({String url, String pass})?> _readJoinPass() async {
    try {
      final j = jsonDecode(await Sms.instance.secretRead(joinPassName) ?? '');
      if (j is Map && j['u'] is String && j['p'] is String && (j['p'] as String).isNotEmpty) return (url: j['u'] as String, pass: j['p'] as String);
    } catch (_) {}
    return null;
  }

  Future<void> _keepJoinPass(String url, String? pass) async {
    final p = pass?.trim() ?? '';
    _joinPass = p.isEmpty ? null : (url: url, pass: p);
    try {
      await Sms.instance.secretKeep(joinPassName, p.isEmpty ? '' : jsonEncode({'u': url, 'p': p}));
    } catch (_) {}
  }

  /// The pass phrase the hub at [url] is shown, where it asks one: this device's own relay's, or the one given for it.
  String? _passFor(String url) {
    final host = _host;
    if (host != null && host.isMine(url)) return host.ownPass;
    final j = _joinPass;
    return j != null && j.url == url ? j.pass : null;
  }

  /// A pass phrase given for the relay this app uses (it asked for one, or the one given was wrong): kept, and the
  /// relay asked again with it at once.
  Future<void> setRelayPass(String pass) async {
    await _keepJoinPass(hubUrl, pass);
    _hub?.passAgain();
    notifyListeners();
  }

  /// How a relay hosted from an app is dialled (hub_link.dart, HubDials.hosted): this device's own in memory, anyone
  /// else's over the direct network by the node its address names.
  Future<HubLink> _dialHosted(String url) {
    final a = GhostRelayAddress.parse(url);
    if (a == null) return Future.error(const HubDialRefused('That isn\'t a relay\'s address.'));
    final host = _host;
    if (host != null && host.relayId == a.relay) return host.dialHere();
    return dialOverDirect(_p2p, a);
  }

  HubCarrier _hubFor(String url, NetSigner signer) {
    final hub = HubCarrier(url: url, signer: signer)..push = _push;
    hub.pass = () => _passFor(hub.url);
    return _presenceOf(hub);
  }

  // --- who is here: presence of people on our own system ------------------------------------------------------------

  /// Goes up whenever anyone's presence on the hub changes (HubCarrier.presence).
  final ValueNotifier<int> presence = ValueNotifier(0);

  // Whether the app is put away, and the names watched beside the phone's own people: told to each hub route as it
  // is made.
  bool _away = false;
  final Set<String> _alsoWatch = {};

  /// Who the relay says is connected changed.
  void _presenceChanged() {
    presence.value++;
    // Whoever came is told this device's card now, where they had not been while away.
    _p2p?.presenceChanged();
  }

  /// [hub], set up for presence: listened to, told whether the app is away, and asked about the extra names.
  HubCarrier _presenceOf(HubCarrier hub) {
    hub.presence.addListener(_presenceChanged);
    hub.awayNow = _away;
    hub.mode = _mode;
    if (_alsoWatch.isNotEmpty) hub.watch(_alsoWatch);
    return hub;
  }

  String _mode = 'online';

  /// How this person chose to be shown (GMFB-34; Me.presenceMode): Online, Away, Busy or Invisible, told to the hub
  /// now and with every sign-in after.
  void setMode(String mode) {
    _mode = mode;
    _hub?.mode = mode;
    _p2p?.setMode(mode);
    _lan?.setMode(mode);
  }

  /// This app put away or in use (main.dart, as it goes to the background and comes back): friends see it (Matt,
  /// 2026-11-17: "presense sensing ... for users who have signed up for a username and are part of our own system").
  ///
  /// [hostAway]: whether the app is put away for a phone's relay, where that is not [away] ([hostAwayIn]: `inactive`
  /// is away for presence but not for the relay).
  void setAway(bool away, {bool? hostAway}) {
    _away = away;
    _hub?.awayNow = away;
    _p2p?.setAway(away);
    _lan?.setAway(away);
    // A phone's relay runs only while the app is in use (lib/relay_host).
    _host?.appAway(hostAway ?? away);
    // Put away, the app may not come back: what the ledger listed is written now, and which route each person is on.
    if (away) unawaited(_ledger?.flush());
    if (away) unawaited(_routesKept?.flush());
  }

  /// Watches these names too (friends by username, lib/friends/buddies.dart), beside those the phone has keys with.
  void watchToo(Iterable<String> ids) {
    final fresh = ids.where(_alsoWatch.add).toList();
    if (fresh.isNotEmpty) _hub?.watch(fresh);
  }

  /// Whether someone on our own system, by their install's name, is using the app now, or when they last were; null
  /// where the hub has said nothing of them.
  ({bool online, DateTime? lastSeen, bool away, bool busy})? presenceOfId(String id) {
    final hub = _hub;
    if (hub == null) return null;
    final here = hub.here.value.contains(id);
    final away = hub.away.value.contains(id);
    final busy = here && hub.busy.value.contains(id);
    final seen = hub.seen[id];
    if (!here && seen == null) return null;
    // Busy shows as busy whether the app is in use or put away; away only where here.
    return (online: here && !away, lastSeen: here && !away ? null : seen, away: here && away && !busy, busy: busy);
  }

  /// How the relay server may wake this app while it is closed (an iPhone's push token; [HubCarrier.push]): kept here
  /// too, so a hub route made later (another server, [setHub]) says it as well.
  void setPush(Map<String, Object?>? value) {
    _push = value;
    _hub?.push = value;
  }

  /// What [setPush] was last given.
  Map<String, Object?>? get push => _push;
  SmsCarrier? get sms => _sms;
  List<Peer> get people => _peers.values.toList();
  bool get on => _app?.flag('net_on') ?? true;
  String get hubUrl {
    final own = _app?.choice('net_hub', '') ?? '';
    return own.trim().isEmpty ? homeHub : own.trim();
  }

  @override
  Peer? byId(String id) => id == this.id && _mineKey != null ? Peer(id: id, key: _mineKey) : _peers[id];

  /// The key this account's devices seal copies to each other with (GMFB-21; Friends.copyKind), once read.
  Uint8List? _mineKey;

  /// This account's own other devices, as one peer: this install's name and the account's key. Null where no Uplink
  /// account is signed in to here (or the routes aren't set up).
  Future<Peer?> mine() async {
    final me = id;
    if (me == null) return null;
    _mineKey ??= await Me.instance.mineKey();
    final key = _mineKey;
    return key == null ? null : Peer(id: me, key: key);
  }

  // No one is found here by an address (found in review, 2026-11-23). The people come from more than one list, and on
  // Android a member of a group is among them under whatever address the group's admin wrote: a friend's number, or
  // "@friend". The first address that matched sent a friend's words to that member. Who an address is, is the record
  // for it to say (Friends.idOf, by the id its key makes), and the routes are asked by that id ([byId]).

  /// Notes something the routes did, for Settings › Network; the newest thirty are kept.
  void _note(String words, {String? via}) {
    recent.insert(0, NetEvent(words, via: via));
    if (recent.length > 30) recent.removeLast();
    notifyListeners();
  }

  /// Sets the routes up. On a computer there are none yet: it speaks through the phone it is paired with.
  /// [carriers] stands in for the phone's own routes (a test).
  ///
  /// Direct's choice is read once, here, for who is a friend ([_readPeers]), and again where the direct route is made,
  /// with nothing awaited between that and the switchboard holding it: a switch made while the routes are set up
  /// (Settings open as the app starts, a sign-in) is taken once they are, as [setDirect] takes it after, never left
  /// half made (the review of Direct's switch, 2026-11-23: switched on then, no direct network was ever made and
  /// Settings said "Starting…" for ever; switched off, the node was made and friends told all the same).
  Future<void> start(AppState app, {List<Carrier>? carriers}) async {
    if ((Sms.paired && !Sms.ownNetwork) || _board != null) return;
    _app = app;
    // The relay the invite links made here name, where it is not Uplink's own (lib/invites/link_relay.dart).
    LinkRelay.here = () => relayHostForLinks(hubUrl);
    final wantDirect = directOn;
    // This install's own name among its identity's devices, made once and kept. Where the choices it is kept with came
    // from another device (a backup restored here), a new one: they bring the name with them, so two devices would be
    // one to the hub, to forward secrecy and to the circles' keys. It is known by the direct network's node key, which is
    // kept where the install keeps its keys and does not come with a backup, while the node id made from it does.
    var device = app.choice('hub_device', '');
    if (device.length == 32 && await _restoredHere(app)) {
      device = '';
      // What the other device said of its own place on the direct network is not this one's.
      for (final name in [P2p.idName, P2p.cardName, P2p.toldName]) {
        app.set(name, '');
      }
    }
    if (device.length != 32) {
      device = NetCrypto.hex(NetCrypto.randomBytes(16));
      app.set('hub_device', device);
    }
    HubCarrier.device = device;
    _device = device;
    try {
      final me = await Sms.instance.netIdentity();
      id = me.id;
      // The account's key, read before any route is up: until it was, nothing the account's other devices sent to its
      // own name could be opened ([byId]), and it was read only once this device sent a copy itself. So a device just
      // opened dropped every copy the relay had kept for it (Matt, 2026-11-23: "messages are not in sync across mobile
      // and desktop").
      await mine();
      // The local network route's ground, before the people are read: with the route on, who is a friend is asked.
      _lanGround = lanGround();
      await _readPeers(direct: wantDirect);
      final signer = _signer = _PhoneSigner(me.id, me.key);
      final List<Carrier> routes;
      if (carriers != null) {
        routes = [...carriers];
      } else {
        final hub = _hub = _hubFor(hubUrl, signer);
        // Where this account lives, said to the relay at every sign-in with where its friends on other relays do; its
        // changes are the routes' (Settings › Routes says when the record couldn't be made).
        _homes = Homes(signer: signer, read: (key) => app.choice(key, ''), write: app.keep)
          ..attach(hub)
          ..addListener(notifyListeners);
        final sms = _sms = SmsCarrier(_PhoneSms());
        routes = [hub, sms];
      }
      // This device's forward secrecy (GMFB-26): its prekeys in the secret store beside the account's words, never in
      // the account's backup. Where that store can't be read, none: everything is sealed the old way, as before.
      // Where it can't be read yet (an iPhone's Keychain before its first unlock), tried again every half minute and as
      // the app comes back; until then everything is sealed the old way, with no prekey, which tells friends to do the
      // same (ForwardSecrecy.sawOld), and forward-secret packets are passed on to a sibling device, not answered.
      final fs = ForwardSecrecy(device: device, secrets: _SecretFsStore(), plain: _ChoiceFsStore(app));
      if (!await fs.tryLoad()) _fsAgain(fs);
      // The direct route, where this build has the core and the person has switched Direct on ([directOn]), and had
      // when the people were read (who is a friend is asked only then); otherwise nothing of it is made, the core's
      // library not even opened, until it is ([setDirect], below where it was switched on meanwhile). Its node key in
      // the secret store beside the account's words, never in the account's backup; a computer's node up whenever the
      // route is on, a phone's only while there is something to say. Made apart from the other routes: a core that
      // fails to load (a library missing, or built for another machine) costs the direct route alone, and Settings ›
      // Routes says why (second review, M3). From here to the switchboard holding it nothing is awaited.
      final madeDirect = wantDirect && directOn;
      final p2p = _p2p = madeDirect ? _makeDirect(signer, device, app) : null;
      if (p2p != null) routes.add(p2p.carrier);
      // The local network route (lib/net/lan), where this build has the ground for one: made with the others and left
      // off, opening nothing, until the person switches it on ([lanOn]). A computer's runs whenever it is on, a phone's
      // while the app is in use.
      final ground = _lanGround;
      final lan = _lan = ground == null ? null : LanCarrier(me: me.id, ground: ground, people: _lanPeople, policy: Sms.computer ? const LanPolicy.computer() : const LanPolicy());
      if (lan != null) {
        lan
          ..setMode(_mode)
          ..setAway(_away)
          ..changed.addListener(_lanChanged);
        routes.add(lan);
      }
      final board = _board = Switchboard(me: me.id, peers: this, carriers: routes, fs: fs);
      // The routes the person switched off; Direct and the local network by their own choices, whatever `net_off` says
      // of them.
      board.off.addAll(app.choice('net_off', '').split(',').where((s) => s.isNotEmpty && s != P2pCarrier.routeId && s != LanCarrier.routeId));
      if (!madeDirect) board.off.add(P2pCarrier.routeId);
      if (lan != null && !lanOn) board.off.add(LanCarrier.routeId);
      board.changed.addListener(notifyListeners);
      board.usedChanged.addListener(_routesUsedChanged);
      _keepRoutes(board, me.id);
      _subs.add(board.received.listen(_received));
      if (p2p != null) _holdDirect(board, p2p, me.id, device);
      // A relay hosted from this device (lib/relay_host), where it can host one: started now where the person has it
      // on, before the hub's route dials, which may be to it; and the way to any relay hosted from an app.
      HubDials.hosted = _dialHosted;
      _joinPass = await _readJoinPass();
      final host = _host ??= relayHostMaker();
      if (host != null) {
        host.addListener(_hostChanged);
        // Not waited for: a slow start (its folder, its link helpers) held up every route (found in the second review,
        // 2026-11-23). A route to it waits for it itself, as dialling it in memory waits for its start.
        unawaited(host.startIfOn().catchError((Object _) {}));
      }
      // People come and go as keys are exchanged and encryption is turned on and off.
      _subs.add(Sms.instance.prefsChanged.stream.listen((_) => refresh()));
      error = null;
      await _apply();
      // What came by text while the app was closed.
      for (final kept in await Sms.instance.netSmsDrain()) {
        Sms.instance.netSms.add(kept);
      }
      // Direct switched while the routes were set up: taken now, in its turn, as a switch after would be.
      if (identical(board, _board) && directOn != madeDirect) await setDirect(directOn);
    } catch (e) {
      error = '$e';
    }
    notifyListeners();
  }

  /// Whether the choices came here from another device: they say a node id was made here, and no node key is kept
  /// here. A secret store that can't be read says nothing either way.
  static Future<bool> _restoredHere(AppState app) async {
    if (app.choice(P2p.idName, '').isEmpty) return false;
    try {
      return (await Sms.instance.secretRead(P2p.keyName) ?? '').isEmpty;
    } catch (_) {
      return false;
    }
  }

  /// This device's hold on the direct network, made once Direct is switched on, where the build has a core
  /// ([p2pNode]); null where it has none, or where the core could not be made or held (then [directProblem] says why).
  /// The node is made the first time and kept ([_node]): a direct network made again holds the same one.
  P2p? _makeDirect(NetSigner signer, String device, AppState app) {
    directProblem = null;
    try {
      final make = p2pNode;
      if (make == null) return null;
      var node = _nodeBy == make && _nodeOf == signer.id ? _node : null;
      if (node == null) {
        // Another account's, or another maker's: let go of, not started again for this one.
        final other = _node;
        _node = null;
        if (other != null) letP2pNodeGo(other);
        node = make();
        _node = node;
        _nodeBy = make;
        _nodeOf = signer.id;
      }
      if (node == null) {
        directProblem = 'This build of the app doesn\'t carry the direct network\'s core, so Direct can\'t be switched on here. The other routes work as before.';
        return null;
      }
      return P2p(
        node: node,
        signer: signer,
        device: device,
        secrets: _SecretFsStore(),
        plain: _ChoiceFsStore(app),
        friends: () => friends,
        mine: mine,
        // Whom the relay says is connected now: nothing about the direct network is said to anyone it would only keep it
        // for. Where there is no relay's route (a test's routes), anyone.
        present: (id) => _hub == null || _hub!.here.value.contains(id),
        policy: Sms.computer ? const P2pPolicy.computer() : const P2pPolicy(),
      );
    } catch (e) {
      directProblem = _couldNot(e);
      return null;
    }
  }

  /// Why the direct route is not there, in words to show (Settings › Routes).
  static String _couldNot(Object e) => 'The direct route could not be started on this device ($e). The other routes work as before.';

  /// Holds [p2p], whose route is on [board] already: it hears the routes, is told how the person chose to be shown,
  /// whether the app is put away and the link helpers of the relay in use, reads what it keeps, and the ledger is
  /// started over it. As the routes are set up, and when Direct is switched on later. Where the core breaks its word on
  /// the way, nothing of it is held, and Settings › Routes says why.
  void _holdDirect(Switchboard board, P2p p2p, String me, String device) {
    try {
      p2p
        ..attach(board)
        ..setMode(_mode)
        ..setAway(_away)
        ..addListener(_directChanged);
      _followHelpers(_hub);
      // The relay names its link helpers as the app signs in to it. Signed in to already (Direct switched on after),
      // it will not name them again until the next sign-in: they are given now.
      final hub = _hub;
      // (As the relay's own naming is taken: [_helpersSaid], which keeps a hosted relay's.)
      if (hub != null && hub.signedInAt > 0) _helpersSaid();
      _loadDirect(p2p);
    } catch (e) {
      board.remove(p2p.carrier.id);
      _followHelpers(null);
      p2p.removeListener(_directChanged);
      unawaited(p2p.shutdown().catchError((Object _) {}));
      _p2p = null;
      directProblem = _couldNot(e);
      return;
    }
    // The ledger, where there is a direct route to compare it over (docs/OPEN_NETWORK.md, section 3): told by the
    // switchboard what went and came, kept with the choices of this device only, and compared with friends' devices as
    // direct links are proved. Without a direct route nothing could compare it, so nothing is listed.
    _startLedger(board, p2p, me, device);
    // The relay on this device takes it (channel 1), where one runs.
    _host?.directChanged();
  }

  /// Switches Direct on or off (Settings › Routes), kept as the person's choice ([directName]), without the app
  /// starting again. On: the node, the route and the ledger are made as a start with Direct on makes them, and the
  /// route is started where there is anyone to reach (a computer's node comes up with it, a phone's when there is
  /// something to say). Off: every link is closed, the node stopped, nobody let in, and the route and the ledger taken
  /// out, so nothing of the direct network runs or is heard until Direct is switched on again. One change at a time,
  /// in the order asked; before the routes are set up, the choice alone, which they read.
  Future<void> setDirect(bool on) {
    final turn = _directTurn.then((_) => _setDirect(on));
    _directTurn = turn.catchError((Object _) {});
    return turn;
  }

  Future<void> _setDirect(bool on) async {
    if (p2pNode == null) return;
    _app?.set(directName, on ? 'on' : 'off');
    final board = _board, me = id, signer = _signer, device = _device, app = _app;
    if (board == null || me == null || signer == null || device == null || app == null) return notifyListeners();
    if (on) {
      board.off.remove(P2pCarrier.routeId);
      if (_p2p == null) {
        // Who is a friend, which only the direct route asks: asked now, as the people are read with Direct on.
        Set<String>? friends;
        try {
          friends = await _friendsAmong(Map.of(_peers));
        } catch (_) {}
        if (!identical(board, _board) || !directOn || _p2p != null) return;
        if (friends != null) _friendIds = friends;
        final p2p = _p2p = _makeDirect(signer, device, app);
        if (p2p != null) {
          board.add(p2p.carrier);
          _holdDirect(board, p2p, me, device);
        }
      }
    } else {
      board.off.add(P2pCarrier.routeId);
      directProblem = null;
      await _dropDirect(board);
    }
    if (!identical(board, _board)) return;
    await _apply();
    notifyListeners();
  }

  /// Takes the direct route out of [board], and the ledger with it: every link closed, the node stopped and nobody let
  /// in (P2p.shutdown), nothing of the direct network heard. The node itself is kept, stopped, for Direct switched on
  /// again. The ledger's lists stay, marked as not kept from now on (Ledger.pause): what comes while Direct is off is
  /// listed nowhere, and is never taken for something the relay dropped.
  Future<void> _dropDirect(Switchboard board) async {
    final p2p = _p2p, ledger = _ledger, check = _check;
    _p2p = null;
    _ledger = null;
    _check = null;
    _p2pTimer?.cancel();
    _p2pTimer = null;
    _followHelpers(null);
    if (p2p != null) board.remove(p2p.carrier.id);
    if (check != null) {
      check.removeListener(_directChanged);
      await check.stop();
    }
    if (ledger != null) {
      ledger.removeListener(_directChanged);
      if (identical(board.log, ledger)) board.log = null;
      await ledger.pause();
      await ledger.shutdown();
    }
    if (p2p != null) {
      p2p.removeListener(_directChanged);
      await p2p.shutdown();
    }
    // The relay on this device lets it go.
    _host?.directChanged();
    _directChanged();
  }

  /// "Only through link helpers" (Settings › Routes › Direct): kept as the direct network keeps it
  /// ([P2p.helpersOnlyName]), so it can be chosen before Direct is ever switched on, and the first link already shows
  /// friends' devices the link helper's address and never this one's; told to the direct network where it runs.
  bool get helpersOnly => _p2p?.helpersOnly ?? _app?.choice(P2p.helpersOnlyName, '') == 'on';

  Future<void> setHelpersOnly(bool only) async {
    final p2p = _p2p;
    if (p2p != null) return p2p.setHelpersOnly(only);
    _app?.keep(P2p.helpersOnlyName, only ? 'on' : 'off');
    notifyListeners();
  }

  /// The link helpers the relay in use named as the app last signed in to it (HubCarrier.helpers); null until it has
  /// signed in to it once. What Settings › Routes says of Direct before it is on: where the relay names none, devices
  /// link only where they can reach each other as they are.
  List<String>? get relayHelpers {
    final hub = _hub;
    return hub == null || hub.signedInAt <= 0 ? null : hub.helpers.value;
  }

  /// Where the ledger is kept: files of its own, out of any backup (kept_files.dart; the review, D6); under a test,
  /// memory, so nothing is written where this computer's own app keeps its files (a test gives its own folder where
  /// that is what it looks at). Null where there is nowhere (a browser): then no ledger is kept.
  static FsStore? Function() ledgerStore = defaultLedgerStore;
  static FsStore? defaultLedgerStore() => PlatformInfo.environment.containsKey('FLUTTER_TEST') ? MemoryFsStore() : ledgerFiles();

  /// Sets up the ledger and its check over [board] and [p2p], where there is somewhere to keep it: the board writes
  /// what goes and comes in it, and the check compares it over direct links.
  void _startLedger(Switchboard board, P2p p2p, String me, String device) {
    try {
      final store = ledgerStore();
      if (store == null) return;
      // Friends as they are each time it asks: the set is made anew whenever the people are read again.
      final ledger = _ledger = Ledger(store: store, me: me, device: device, isFriend: (id) => _friendIds.contains(id));
      board.log = ledger;
      ledger.addListener(_directChanged);
      unawaited(ledger.load());
      final check = _check = LedgerCheck(ledger: ledger, board: board, p2p: p2p, relay: () => _hub);
      check.holders.addAll(_holders);
      check.addListener(_directChanged);
      check.start();
    } catch (_) {
      board.log = null;
      _ledger = null;
      _check = null;
    }
  }

  /// The app has come back after [away] (main.dart): the relay server's connection is made again where it may have
  /// died meanwhile, and what friends were sent and have not answered goes again once it is up (Friends).
  void resume(Duration away) {
    _hub?.nudge(away: away);
    final fs = _board?.fs;
    if (fs != null && !fs.loaded) unawaited(fs.tryLoad());
    // The network may be another than when the app was put away: the local network route says it is here again, and the
    // direct route's node looks at its paths again.
    _lan?.networkChanged();
    final p2p = _p2p;
    if (p2p != null) {
      if (p2p.loaded) {
        p2p.networkChanged();
      } else {
        unawaited(p2p.tryLoad());
      }
    }
  }

  Timer? _fsTimer;

  /// Tries [fs]'s load again every half minute until it works.
  void _fsAgain(ForwardSecrecy fs) {
    _fsTimer?.cancel();
    _fsTimer = Timer.periodic(const Duration(seconds: 30), (t) async {
      if (fs.loaded || await fs.tryLoad()) t.cancel();
    });
  }

  /// Reads from the phone who the routes reach, each with their name as the contacts have it. [direct]: whether Direct
  /// is on for who is a friend; where it is now, unless said.
  Future<void> _readPeers({bool? direct}) async {
    final list = await Sms.instance.netPeers();
    final found = <String, Peer>{};
    for (final p in list) {
      // Their name as the phone's contacts have it, where they do.
      String? name;
      try {
        name = (await Sms.instance.contact(p.address)).name;
      } catch (_) {}
      found[p.id] = Peer(id: p.id, key: p.key, address: p.address, name: name);
    }
    // Who of them is a friend, which is the direct route's question and the local network route's, asked only where one
    // of them is switched on: whom the
    // records that say so name, by the id their key makes, and never by an address. On Android the people come from
    // those encryption is on with, the members of this phone's groups and friends by username together (MainActivity's
    // netPeers), and a group member's address is whatever the group's admin wrote: "@anything", or a real friend's
    // number (second review, M1).
    final friends = (direct ?? directOn) || lanOn ? await _friendsAmong(found) : <String>{};
    _peers
      ..clear()
      ..addAll(found);
    _friendIds = friends;
  }

  /// Those of [found] the records say are friends: friends by username in the state `yes` (lib/friends/buddies.dart),
  /// by their id and only where their key makes it; and friends by number (E2eState.isFriend), by the id the key on
  /// their record makes (android E2e.state). A record that can't be read now leaves whoever was a friend by it one.
  Future<Set<String>> _friendsAmong(Map<String, Peer> found) async {
    final friends = <String>{};
    try {
      for (final j in jsonDecode(await Sms.instance.buddiesKept()) as List) {
        final b = Buddy.fromJson(j);
        if (b == null || b.state != 'yes') continue;
        try {
          if (NetCrypto.idOf(base64Decode(b.key)) == b.id) friends.add(b.id);
        } catch (_) {}
      }
    } catch (_) {
      friends.addAll(_friendIds);
    }
    try {
      for (final s in await Sms.instance.e2eList()) {
        if (s.isFriend && s.id != null) friends.add(s.id!);
      }
    } catch (_) {
      friends.addAll(_friendIds);
    }
    return friends.where(found.containsKey).toSet();
  }

  /// Stops the routes and forgets them: the app is closing, or a test is over.
  Future<void> shutdown() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _fsTimer?.cancel();
    _fsTimer = null;
    _p2pTimer?.cancel();
    _p2pTimer = null;
    final board = _board, p2p = _p2p, ledger = _ledger, check = _check, lan = _lan;
    _board = null;
    _hub = null;
    _sms = null;
    _p2p = null;
    _ledger = null;
    _check = null;
    _lan = null;
    _lanGround = null;
    _lanAccounts = {};
    _lanSaid = null;
    _lanSayLater?.cancel();
    _lanSayLater = null;
    lan?.changed.removeListener(_lanChanged);
    // The local network route goes first, whatever goes wrong with the rest after: left running, it would go on saying
    // this account's marks to the network with nothing holding it (found in review, 2026-11-26).
    try {
      await lan?.dispose();
    } catch (_) {}
    _followHelpers(null);
    _homes?.dispose();
    _homes = null;
    // The relay this device hosts stops with the routes: everyone on it sees it gone; its choice and its folder stay.
    final host = _host;
    _host = null;
    if (host != null) {
      host.removeListener(_hostChanged);
      await host.shutdown();
    }
    HubDials.hosted = null;
    _joinPass = null;
    if (check != null) {
      check.removeListener(_directChanged);
      await check.stop();
    }
    if (ledger != null) {
      ledger.removeListener(_directChanged);
      board?.log = null;
      await ledger.shutdown();
    }
    if (board != null) {
      board.changed.removeListener(notifyListeners);
      board.usedChanged.removeListener(_routesUsedChanged);
      await board.stop();
    }
    // Which route each person was on is written as the routes go, for the next run.
    final routesKept = _routesKept;
    _routesKept = null;
    if (routesKept != null) {
      try {
        await routesKept.flush();
      } catch (_) {}
      routesKept.dispose();
    }
    if (p2p != null) {
      p2p.removeListener(_directChanged);
      await p2p.shutdown();
    }
    await board?.dispose();
    _peers.clear();
    _friendIds = {};
    recent.clear();
    id = null;
    // The account's key goes with it: the next account signed in here reads its own.
    _mineKey = null;
    _signer = null;
    _device = null;
    // The node goes with the routes (stopped by P2p.shutdown above), let go of in the core: the next account signed in
    // here has one of its own, with nothing of this one's (its port least of all).
    final node = _node;
    _node = null;
    _nodeBy = null;
    _nodeOf = null;
    if (node != null) letP2pNodeGo(node);
    // A switch of Direct still under way belongs to the routes as they were (it sees they are gone): the next routes'
    // switching waits on none of it.
    _directTurn = Future.value();
    directProblem = null;
  }

  /// Reads the people again, and starts or stops the routes to suit: after encryption was turned on with someone,
  /// or off.
  Future<void> refresh() async {
    if (_board == null) return;
    try {
      await _readPeers();
    } catch (_) {}
    await _apply();
    // Someone became a friend, or is one no longer: the direct route tells the one its card and forgets the other's,
    // and the local network route links with the one and lets go of the other.
    unawaited(_p2p?.refresh());
    _lan?.refresh();
    notifyListeners();
  }

  /// What else needs the relay server's hub besides the people encryption is on with: Settings › Me, which links
  /// accounts and verifies the number through it ([want]).
  final Set<String> _wanting = {};

  /// Says whether [who] needs the relay server connected. While anything does, the hub is dialled even with nobody
  /// to reach: it was dialled only for people encryption is on with, so a phone with none never reached the relay
  /// and Settings › Me said it wasn't connected (Matt, 2026-11-14: "it's not conecting to the relay it seems it
  /// says I can't verify my number until it connects to the relay which should be live").
  Future<void> want(String who, bool yes) async {
    final changed = yes ? _wanting.add(who) : _wanting.remove(who);
    if (changed) await _apply();
  }

  /// Starts or stops the routes to match the person's choices. With nobody to reach and nothing that needs the
  /// relay server, nothing dials out; with nobody to reach but something that needs it, the hub alone does.
  Future<void> _apply() async {
    final board = _board;
    if (board == null) return;
    if (on && _peers.isNotEmpty) {
      await board.start();
      _hub?.watch([..._peers.keys, ..._alsoWatch]);
    } else if (_wanting.isNotEmpty && !board.off.contains('hub')) {
      for (final c in board.carriers) {
        await (c.id == 'hub' ? c.start() : c.stop()).catchError((_) {});
      }
    } else {
      await board.stop();
    }
    // A relay on this device takes joiners over Direct whether or not anyone here is to be reached now: its route runs
    // while the relay does, with Direct switched on (found in the fourth review, 2026-11-23: with nobody to reach the
    // route was stopped, and the relay's node with it).
    if (on && directOn && _host?.state == HostState.up && !board.off.contains(P2pCarrier.routeId)) {
      for (final c in board.carriers) {
        if (c.id == P2pCarrier.routeId) await c.start().catchError((_) {});
      }
    }
    // The relay on this device follows the route as it now stands (its node brought up for joiners, or let go).
    _host?.directChanged();
  }

  HostState? _hostWas;

  /// The relay on this device changed: shown, and the routes set again where it started or stopped ([_apply]).
  void _hostChanged() {
    final now = _host?.state;
    if (now != _hostWas) {
      _hostWas = now;
      unawaited(_apply().catchError((Object _) {}));
    }
    notifyListeners();
  }

  /// Turns the whole network on or off, and keeps the choice.
  Future<void> setOn(bool value) async {
    _app?.setFlag('net_on', value);
    await _apply();
    notifyListeners();
  }

  /// Switches the route [id] on or off, and keeps the choice.
  Future<void> setRoute(String id, bool value) async {
    // Direct starts off, and its choice is its own ([setDirect], [directName]).
    if (id == P2pCarrier.routeId) return setDirect(value);
    // So does the local network route, and its choice is its own too ([setLan], [lanName]).
    if (id == LanCarrier.routeId) return setLan(value);
    final board = _board;
    if (board == null) return;
    // The person's choice is kept whatever happens to be running; then the routes are started or stopped to suit.
    // It was handed straight to the route as "on only if there is someone to reach", and with nobody encrypted that
    // was "off", which the switchboard writes down as switched off: the switch flipped back and could never be
    // turned on again (Matt, 2026-11-14: "I also can't toggle the relay server back on or SMS").
    if (value) {
      board.off.remove(id);
    } else {
      board.off.add(id);
    }
    _app?.set('net_off', board.off.where((r) => r != P2pCarrier.routeId && r != LanCarrier.routeId).join(','));
    if (!value) await board.setOn(id, false);
    await _apply();
    notifyListeners();
  }

  /// Whether the relay in use is Uplink's own default one.
  bool get onDefaultHub => hubUrl == defaultHub;

  /// Moves to the relay at [typed] (GMFB-25; relay_choice.dart), but only once an Uplink relay answers there:
  /// the address is tidied ([tidyRelayAddress]), asked ([checkRelay]), and [confirm], where given, asked with the
  /// tidied address before anything changes. Empty, or our own address, is ours again and needs no check. Says why
  /// it didn't move, or null where it did (or the person said no at [confirm]: then declined is true).
  ///
  /// [decide], where given in [confirm]'s place, is asked with what the relay said of itself ([RelayCheck]: whether it
  /// runs in someone's app, whether it asks for a pass phrase) and answers with the person's yes and the phrase they gave.
  /// A relay that asks for a phrase is not moved to without one (but this device's own, whose phrase the app knows).
  ///
  /// [askFirst], where given, is asked with the tidied address before anything is dialled: a relay's link opened from
  /// elsewhere is asked about before the app connects to the address it carries (found in the second review,
  /// 2026-11-23: it dialled first). No is declined, nothing dialled.
  Future<({String? problem, bool declined})> useRelay(String typed, {HubDial? connect, Duration timeout = const Duration(seconds: 8), Future<bool> Function(String url)? confirm, Future<({bool yes, String? pass})> Function(String url, RelayCheck check)? decide, Future<bool> Function(String url)? askFirst}) async {
    final url = tidyRelayAddress(typed);
    if (url == null) return (problem: 'That isn\'t a relay server\'s address. It looks like relay.example.com or wss://relay.example.com/hub.', declined: false);
    if (url.isEmpty || url == defaultHub) {
      if (!onDefaultHub) await setHub('');
      return (problem: null, declined: false);
    }
    if (url == hubUrl) return (problem: null, declined: false);
    if (askFirst != null && !await askFirst(url)) return (problem: null, declined: true);
    final check = await checkRelay(url, connect: connect, timeout: timeout);
    if (!check.ok) return (problem: check.problem, declined: false);
    String? pass;
    if (decide != null) {
      final d = await decide(url, check);
      if (!d.yes) return (problem: null, declined: true);
      pass = d.pass?.trim();
    } else if (confirm != null && !await confirm(url)) {
      return (problem: null, declined: true);
    }
    if (check.asksPass && (pass == null || pass.isEmpty) && !(_host?.isMine(url) ?? false)) return (problem: 'This relay asks for a pass phrase: whoever runs it can give it to you.', declined: false);
    await setHub(url, relay: check.relay, pass: pass);
    return (problem: null, declined: false);
  }

  /// Uses another relay server ([url] empty: ours again). The route is taken out and one for the new address put
  /// in its place: the rest of the app does not know. Settings › Routes goes through [useRelay], which checks first.
  ///
  /// Moving is signing a home record with the next count (homes.dart): it is made here, for the address the new relay
  /// is known by ([relay], what it said of itself when it was checked, where it said anything), and given to the relay
  /// being left while it is still connected, so that relay knows where this account lives now. The new relay is given
  /// it as the app signs in there, and friends are told a few at a time (lib/friends/buddies.dart).
  ///
  /// [pass]: the phrase the new relay asks for, where it asks one (kept for it alone).
  Future<void> setHub(String url, {HubRelay? relay, String? pass}) async {
    final next = Homes.addressOf(relay, url.trim().isEmpty ? defaultHub : url.trim());
    try {
      // (The relay being left answers the new record, and friends on it are told, before it is left: ten seconds.)
      if (next != null) await _homes?.moveTo(next).timeout(const Duration(seconds: 10));
    } catch (_) {}
    _app?.set('net_hub', url.trim());
    if (pass != null) await _keepJoinPass(url.trim(), pass);
    final board = _board, old = _hub, me = id;
    if (board == null || old == null || me == null) return;
    await old.stop();
    old.presence.removeListener(_presenceChanged);
    final hub = _hub = _hubFor(hubUrl, old.signer);
    _homes?.attach(hub);
    presence.value++;
    // Another relay names its own link helpers as the app signs in to it; the one left behind's are not used on. But a
    // relay hosted from an app is reached over Direct by the helpers in use now (and names them itself as the app signs
    // in): emptied first, its dial would find nothing.
    if (!isGhostRelay(url)) _p2p?.setHelpers(const []);
    _followHelpers(hub);
    board.add(hub);
    await _apply();
    notifyListeners();
  }

  /// What [p] is called in what the routes did ([recent]): their name, else their address, else the start of their
  /// install's name. An empty address is none: a member of a group known here only by the group has one.
  static String _who(Peer p) {
    final name = p.name ?? '', address = p.address ?? '';
    return name.isNotEmpty ? name : (address.isNotEmpty ? address : p.id.substring(0, p.id.length < 6 ? p.id.length : 6));
  }

  void _received(Received r) {
    final who = _who(r.peer);
    if (r.envelope.kind == 'ping') _note('A test came from $who', via: r.via);
    for (final l in _listeners.toList()) {
      l(r);
    }
  }

  final List<void Function(Received)> _listeners = [];

  /// What comes by the routes, for whoever in the app it is for (calls, receipts).
  void listen(void Function(Received) onReceived) => _listeners.add(onReceived);
  void unlisten(void Function(Received) onReceived) => _listeners.remove(onReceived);

  /// Sends [envelope] to [peer] by the routes (Switchboard.send).
  Future<Delivery> send(Peer peer, Envelope envelope, {bool metered = false, bool urgent = false, Set<String>? only}) {
    final board = _board;
    if (board == null) return Future.value(Delivery(envelope.id, tried: const ['the routes are not set up']));
    return board.send(peer, envelope, metered: metered, urgent: urgent, only: only);
  }

  /// Sends a test to [peer], by [only] those routes where given, and says what became of it and how long the
  /// answer took. One sent by SMS is a text on the person's plan, and is not answered (an answer would be one on
  /// theirs): the other phone shows that it came, in its own Settings › Network.
  Future<({Delivery delivery, Duration took})> test(Peer peer, {String? only}) async {
    final began = DateTime.now();
    final d = await send(peer, Envelope(kind: 'ping'), metered: only == 'sms', only: only == null ? null : {only});
    final took = DateTime.now().difference(began);
    final who = _who(peer);
    _note(
      d.sent ? (d.acked ? 'A test reached $who in ${took.inMilliseconds} ms' : d.handed == Handed.held ? 'A test is kept for $who, who is away' : 'A test was sent to $who') : 'A test to $who could not be sent: ${d.tried.join('; ')}',
      via: d.via,
    );
    return (delivery: d, took: took);
  }
}

/// Where this device's prekeys are kept: the Keychain, Android's vault, as the account's words are (Sms.secretKeep).
class _SecretFsStore implements FsStore {
  @override
  Future<String?> read(String name) => Sms.instance.secretRead(name);
  @override
  Future<void> write(String name, String value) => Sms.instance.secretKeep(name, value);
}

/// Where what others offered, and the packets seen, are kept: with the app's choices, drawing nothing again.
class _ChoiceFsStore implements FsStore {
  _ChoiceFsStore(this.app);
  final AppState app;
  @override
  Future<String?> read(String name) async => app.choice(name, '');
  @override
  Future<void> write(String name, String value) async => app.keep(name, value);
}

class _PhoneSigner implements NetSigner {
  _PhoneSigner(this.id, this.publicKey);
  @override
  final String id;
  @override
  final Uint8List publicKey;
  @override
  Future<Uint8List> sign(List<int> message) => Sms.instance.netSign(message);
}

/// Data texts by the phone's native side, for the SMS route.
class _PhoneSms implements SmsBridge {
  @override
  Future<bool> available() => Sms.instance.netSmsAvailable();
  @override
  Future<void> send(String address, Uint8List bytes) => Sms.instance.netSmsSend(address, bytes);
  @override
  Stream<({String address, Uint8List bytes})> get incoming => Sms.instance.netSms.stream;
}
