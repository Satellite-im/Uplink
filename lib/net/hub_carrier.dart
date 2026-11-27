import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../relay_host/address.dart';
import 'carrier.dart';
import 'crypto.dart';
import 'hub_link.dart';
import 'hub_pass.dart';

/// Who this install is to a hub: its name, its public key, and a way to sign with the private one, which stays
/// wherever it is kept (Android's keystore on a phone).
abstract class NetSigner {
  /// Its name on the hub (made from its public key), and the public key itself.
  String get id;
  Uint8List get publicKey;

  /// A signature over [message]: r then s, 64 bytes.
  Future<Uint8List> sign(List<int> message);
}

/// A signer whose key pair is held in Dart: a computer, and the tests.
class KeysSigner implements NetSigner {
  KeysSigner(this.keys);
  final NetKeys keys;
  @override
  String get id => keys.id;
  @override
  Uint8List get publicKey => keys.public;
  @override
  Future<Uint8List> sign(List<int> message) async => NetCrypto.sign(keys, message);
}

/// What a relay says of itself in its hub's hello (relay/lib/federation.dart `card`; docs/OPEN_NETWORK.md, section 4):
/// its own name and key, the address it is known by where it claims one, the relay it stays linked to where it has no
/// address of its own, and whether it talks to other relays. A relay from before says none of it.
class HubRelay {
  const HubRelay({required this.id, required this.key, this.url, this.via, this.fed = false});

  /// The relay's name (NetCrypto.idOf its key) and its public key in base64.
  final String id;
  final String key;

  /// Its hub's address as other relays know it; null where it claims none.
  final String? url;

  /// The public relay it stays linked to, for one with no address of its own (hosted from an app).
  final String? via;

  /// Whether it passes packets to other relays and asks them who someone is.
  final bool fed;

  /// What [said] says, where it is a relay's name and the key the name is made from; null otherwise.
  static HubRelay? from(Object? said) {
    if (said is! Map) return null;
    final id = said['id'], key = said['key'], url = said['url'], via = said['via'];
    if (id is! String || key is! String) return null;
    try {
      final k = base64Decode(key);
      if (k.length != 33 || NetCrypto.idOf(k) != id) return null;
    } catch (_) {
      return null;
    }
    String? hub(Object? x) => x is String && x.length <= 200 && RegExp(r'^wss?://[^\s?#@]+/hub$').hasMatch(x) ? x : null;
    return HubRelay(id: id, key: key, url: hub(url), via: hub(via), fed: said['fed'] == true);
  }

  /// Whether the hub that said [hello] is the relay [address] names: its card names that relay, and its `relaySig` is
  /// that relay's key's signature over `ghost-hub relay v1 `, the hub's number and the place dialled (the node id, or
  /// the relay's name in memory: [GhostRelayAddress.signedHost]; relay/lib/federation.dart, signReached). A copy of
  /// another relay's card proves nothing without the key (found in the third review, 2026-11-23).
  static bool proves(Map hello, GhostRelayAddress address) {
    final relay = from(hello['relay']), sig = hello['relaySig'], nonce = hello['hello'];
    if (relay == null || relay.id != address.relay || sig is! String || nonce is! String) return false;
    try {
      final message = [...utf8.encode('ghost-hub relay v1 '), ...NetCrypto.unhex(nonce), ...utf8.encode(address.signedHost.toLowerCase())];
      return NetCrypto.verify(base64Decode(relay.key), message, base64Decode(sig));
    } catch (_) {
      return false;
    }
  }
}

/// Something that happened in a room: who is in it on joining, then who came and went.
class RoomEvent {
  const RoomEvent(this.room, {this.members, this.came, this.went, this.closed = false, this.replaced = false});
  final String room;

  /// Who is in the room, said on joining it; or who came; or who went. One of them at a time.
  final List<String>? members;
  final String? came;
  final String? went;

  /// The route was lost: nobody in the room can be reached by it until it is joined again.
  final bool closed;

  /// With [closed]: the route was not lost but taken, by another connection of this same device (the hub's 4409: a
  /// second window of the app, GMFB-47). A call is left for it, not mended (VoiceSession).
  final bool replaced;
}

/// The route through a server's hub (relay/lib/hub.dart): this install dials out to it and is found there by its
/// name. It is the one that works between any two networks today, and the one a peer-to-peer route is meant to
/// take the place of (Matt, 2026-11-14: "for right now we can use our servers ... but in the future id like to be
/// able to use a P2P decentralized relay").
///
/// A packet for someone who is not connected is kept by the hub and handed over when they next are. The hub sees
/// names and sizes, never contents. It also keeps rooms ([join]), which a voice room and a group are made on.
class HubCarrier implements Carrier {
  HubCarrier({required this.url, required this.signer, Duration? retry, HubDial? dial, DateTime Function()? now})
      : _retry = retry ?? const Duration(seconds: 3),
        _dial = dial ?? dialHub,
        _now = now ?? DateTime.now;

  /// What [signedInAt] and [heardAt] are read from: the time, or a test's clock.
  final DateTime Function() _now;

  /// When the connection now up signed in (its `ok`), and when anything last came on it, in milliseconds; 0 before the
  /// first. A frame that came after a moment proves the connection was alive then: the relay's frames to this app come in
  /// order on it, so whatever the relay put on it before that frame came first (lib/net/ledger.dart).
  int signedInAt = 0, heardAt = 0;

  /// When the relay last started, by this device's clock, as it said at the last sign-in (`since`, with its `now`): what
  /// it kept for someone before then went with the restart (relay/lib/hub.dart). 0 where it didn't say (a relay from
  /// before).
  int relayStartedAt = 0;

  /// Whether this install asked to be told when [id] comes and goes ([watch]): only then does [here] say anything of
  /// them.
  bool watching(String id) => _watched.contains(id);

  /// Which of its identity's devices this install is, said in the hello (Net.start sets it): a phone and its computer
  /// can be here at once under one identity, each handed what is sent to it (relay/lib/hub.dart). Empty, as an app
  /// from before said nothing: then another such connection takes this one's place.
  static String device = '';

  /// The hub's address: `wss://gogho.st/hub`.
  final String url;
  final NetSigner signer;
  final Duration _retry;

  /// How the hub is reached (hub_link.dart): a WebSocket to [url] where nothing else was given.
  final HubDial _dial;

  static const greeting = 'ghost-hub v1 ';

  /// What is signed to a hub that takes it (relay/lib/hub.dart greetingV2; found in the review of relays that talk,
  /// 2026-11-23): these words, the host this app dialled ([hostOf], its length first), then the hub's number. A v1
  /// signature says nothing of where it was made, so a relay this app was pointed at, or asked a name of, could pass the
  /// number of this app's own relay along and sign in there as this app with the answer; a v2 one is good only at a
  /// relay reached by that host, and a relay that has seen this account sign in with v2 takes no v1 from it again.
  static const greetingV2 = 'ghost-hub v2 ';

  /// The host a v2 sign-in names for [url]: lower case, with its port where it is not the scheme's own. For a relay
  /// hosted from someone's app (`ghost-relay://…`, lib/relay_host/address.dart), the node id of the device it is
  /// dialled at over Direct, which the direct network's handshake proves, or for the app it runs in its own name.
  static String hostOf(String url) {
    final hosted = GhostRelayAddress.parse(url);
    if (hosted != null) return hosted.signedHost;
    final u = Uri.parse(url);
    final usual = u.scheme == 'wss' ? 443 : 80;
    final host = u.host.toLowerCase();
    final shown = host.contains(':') ? '[$host]' : host;
    return u.hasPort && u.port != usual ? '$shown:${u.port}' : shown;
  }

  /// What is signed with v2 to the hub reached at [host], for its number [nonce].
  static List<int> signedV2(String host, List<int> nonce) {
    final bytes = utf8.encode(host);
    return [...utf8.encode(greetingV2), bytes.length.clamp(0, 255), ...bytes.take(255), ...nonce];
  }

  @override
  String get id => 'hub';
  @override
  String get name => 'Relay server';
  @override
  String get about => 'Through a server on the internet. Works between any two networks; the server sees who talks to whom, never what is said.';
  /// The longest packet the hub's route carries in one piece (the hub itself takes 64 KiB, with its own header). The
  /// direct route holds to the same (p2p/p2p_carrier.dart), so a packet made for one fits the other.
  static const maxPacket = 60 * 1024;

  @override
  CarrierTraits get traits => const CarrierTraits(maxPacket: maxPacket);
  @override
  final ValueNotifier<CarrierState> state = ValueNotifier(CarrierState.off);
  @override
  String? problem;

  final _arrived = StreamController<Arrived>.broadcast();
  final _rooms = StreamController<RoomEvent>.broadcast();
  final _roomPackets = StreamController<({String room, String from, Uint8List bytes})>.broadcast();
  final _handles = StreamController<Map<String, dynamic>>.broadcast();
  @override
  Stream<Arrived> get arrived => _arrived.stream;

  /// Who came and went in the rooms this install is in.
  Stream<RoomEvent> get roomEvents => _rooms.stream;

  /// What the others in a room sent to it.
  Stream<({String room, String from, Uint8List bytes})> get roomPackets => _roomPackets.stream;

  /// Reactions in rooms (relay/lib/hub.dart toRoomReaction), apart from other room packets.
  final _roomReactions = StreamController<({String room, String from, Uint8List bytes})>.broadcast();
  Stream<({String room, String from, Uint8List bytes})> get roomReactions => _roomReactions.stream;

  /// Whether the relay server connected to takes reactions as a packet of their own ([sendReaction]); a server from
  /// before keeps them as an ordinary kept packet instead.
  bool takesReactions = false;

  /// Sends a reaction to a room this install is in, kept for whoever comes later (relay/lib/hub.dart toRoomReaction).
  void sendReaction(String room, Uint8List packet) {
    if (!_ready || !_joined.containsKey(room)) throw CarrierError('not in that room');
    _ws?.say([4, ...NetCrypto.unhex(room), ...packet]);
  }

  /// What the server's keeper of handles says to this install (relay/lib/handles.dart): every message that starts
  /// `{"dir": …}`. lib/me/me.dart listens.
  Stream<Map<String, dynamic>> get handles => _handles.stream;

  /// What the relay says of home records (relay/lib/federation.dart): its answers to `home` and `home?`, apart from
  /// the handles' own. lib/net/homes.dart listens.
  final _homes = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get homes => _homes.stream;

  /// What the relay said of itself in its hello, at the last sign-in; null from a relay from before.
  HubRelay? relay;

  /// Whether the relay said, in its last hello, that it runs in someone's app (relay/lib/hub.dart `hosted`;
  /// lib/relay_host): whoever runs it sees which installs talk and when, and it is up only while their app is.
  bool hosted = false;

  /// Whether the relay asks for a pass phrase (relay/lib/hub.dart `pass`), as its last hello said.
  bool asksPass = false;

  /// The pass phrase for this relay, where the person gave one (the routes keep it: lib/net/net.dart); asked each time
  /// the relay asks for one, so a phrase given since is the one used. Nothing of it is said but a proof made for the one
  /// connection ([HubPass]).
  String? Function()? pass;

  /// Why the relay refused this app's pass phrase at the last sign-in, where it did: `needed` (none given), `wrong`, or
  /// `busy` (too many wrong ones lately, from here, or from strangers while this install is new there). The route then
  /// waits, and is not tried again by itself: a phrase wrong a minute ago is wrong now, and each try would cost this
  /// device more waiting ([nudge] tries again once one is given); after `busy`, as long as the relay says, or
  /// [passBusyWait]. Null once it signs in.
  String? passRefused;
  static const passBusyWait = Duration(minutes: 10);

  /// How long the route waits after the last `busy`, before it asks again; null otherwise.
  Duration? passBusyFor;

  /// What is said first at every sign-in, before anything else can be sent: this account's home record and its
  /// friends' (lib/net/homes.dart), so the relay can route from the first packet on.
  List<Map<String, Object?>> Function()? onSignIn;

  /// The names whose last packet the relay passed on to another relay (`fed` in its answer), and those it did not.
  final Set<String> _crossed = {};
  final Map<int, String> _sentTo = {};

  /// Whether the last packet sent to [id] was passed by this relay to another relay (or is kept for one): false where
  /// it was only kept here, as for someone who lives here.
  bool passedOn(String id) => _crossed.contains(id);

  /// Told each time the relay only kept a packet here for [id], not here and not passed to another relay: for
  /// someone who lives on another relay it means the relay no longer holds their home record (lib/net/homes.dart
  /// says it again).
  void Function(String id)? onKeptHere;

  /// Told when the relay passed nothing on because it holds no record of this account's naming it (`nak` `home`):
  /// lib/net/homes.dart gives it again.
  void Function()? onNoHome;

  /// The names whose last packet waits on this relay for their relay to be reached (`waiting` in its answer): what is
  /// written to them is not sent again as often meanwhile (lib/friends/friends.dart).
  final Set<String> waitingFor = {};

  /// Why the relay refused the last packet to each name it refused, in words to show; gone once one is taken.
  final Map<String, String> refusedWhy = {};

  /// Takes a packet another connection of this install's brought, as though this route had: what another relay was
  /// keeping for this install, handed over while that relay was asked something (lib/net/relay_ask.dart).
  void adopt(String from, Uint8List bytes) => _arrived.add(Arrived(id, bytes, from: from));

  /// Says something to the keeper of handles; false where the route is not up.
  bool sayHandles(Map<String, Object?> what) {
    final ws = _ws;
    if (ws == null || !_ready) return false;
    ws.say(jsonEncode(what));
    return true;
  }

  /// The names, of those asked about ([watch]), that are connected to the hub now.
  final ValueNotifier<Set<String>> here = ValueNotifier(const {});

  /// Of those [here], the ones with the app put away (relay/lib/hub.dart's `away`).
  final ValueNotifier<Set<String>> away = ValueNotifier(const {});

  /// Of those [here], the ones who chose Busy (relay/lib/hub.dart's `busy`; GMFB-34).
  final ValueNotifier<Set<String>> busy = ValueNotifier(const {});

  /// When each of those asked about was last using the app, where the hub knows (`went`, `seen`, `away`).
  final Map<String, DateTime> seen = {};

  /// Goes up whenever [here], [away] or [seen] changes: the one thing a face's presence listens to.
  final ValueNotifier<int> presence = ValueNotifier(0);

  bool _awayNow = false;

  /// This app put away (true) or in use (false), told to the hub so friends watching see it; said again after every
  /// sign-in (Matt, 2026-11-17: "presense sensing ... for users who have signed up for a username").
  bool get awayNow => _awayNow;
  set awayNow(bool value) {
    if (value == _awayNow) return;
    final was = _awaySaid;
    _awayNow = value;
    if (_ready && _awaySaid != was) _ws?.say(jsonEncode({'away': _awaySaid}));
  }

  /// How this person chose to be shown (GMFB-34): 'online', 'away', 'busy' or 'invisible'. Away is said as the app put
  /// away, whatever it is doing; busy and invisible are the hub's own (`mode`), said with every hello too, so someone
  /// invisible never shows as come.
  String get mode => _mode;
  String _mode = 'online';
  set mode(String value) {
    final m = const {'online', 'away', 'busy', 'invisible'}.contains(value) ? value : 'online';
    if (m == _mode) return;
    final wasAway = _awaySaid;
    _mode = m;
    if (!_ready) return;
    _ws?.say(jsonEncode({'mode': _hubMode}));
    if (_awaySaid != wasAway) _ws?.say(jsonEncode({'away': _awaySaid}));
  }

  /// What the hub is told: away where the app is put away or the person chose Away; and of the modes only busy and
  /// invisible, online for the rest.
  bool get _awaySaid => _awayNow || _mode == 'away';
  String get _hubMode => _mode == 'busy' || _mode == 'invisible' ? _mode : 'online';

  /// The link helpers the hub named as this app last signed in to it (relay/lib/hub.dart `helpers`, from
  /// `GHOST_LINK_HELPERS`): what the direct route's node is given (lib/net/p2p). At most [mostHelpers], each an https
  /// address of at most [longestHelper] characters. Empty until the app has signed in, and where the hub names none.
  /// Set anew at every sign-in, so whoever listens is told each time the hub has said, changed or not; a lost
  /// connection leaves them as they were, since that is when they are needed.
  ValueListenable<List<String>> get helpers => _helpers;
  final ValueNotifier<List<String>> _helpers = ValueNotifier(const []);
  static const mostHelpers = 4;
  static const longestHelper = 200;

  HubLink? _ws;
  bool _wanted = false;
  bool _ready = false;

  // The next try at connecting; the number the last packet went with; and how many tries have failed in a row.
  Timer? _again;
  int _seq = 0;
  int _tries = 0;

  /// Packets sent and not yet answered by the hub, by the number each went with ([_seq]).
  final Map<int, Completer<Handed>> _sent = {};

  // The names asked about ([watch]), and the rooms joined and looked at, each with its token: all said again on
  // every sign-in.
  final Set<String> _watched = {};
  final Map<String, String> _joined = {};
  final Map<String, String> _looked = {};
  final _looks = StreamController<({String room, List<String> members})>.broadcast();

  /// The relay's TURN server for calls, with a username and password good for a day, as the hub handed it out with the
  /// last room joined (relay/lib/turn.dart): an RTCIceServer entry. Null where the hub has none (or is from before).
  Map<String, Object>? callRelay;

  /// Who is in each room this install looks at ([look]), as the hub last said.
  final Map<String, List<String>> looking = {};

  /// Who is in a room looked at, each time that changes.
  Stream<({String room, List<String> members})> get looks => _looks.stream;

  /// Asks to be told who is in [room] without joining it: a voice channel's list. Asked again by itself after the
  /// route is lost and comes back. [token] is the room's own: a wrong one is told nothing.
  void look(String room, String token) {
    _looked[room] = token;
    if (_ready) _ws?.say(jsonEncode({'look': room, 'token': token}));
  }

  /// Stops being told who is in [room].
  void unlook(String room) {
    looking.remove(room);
    if (_looked.remove(room) != null && _ready) _ws?.say(jsonEncode({'unlook': room}));
  }

  /// Joins the hub has not answered yet, by room.
  final Map<String, Completer<List<String>>> _joining = {};

  @override
  Future<void> start() async {
    if (_wanted) return;
    _wanted = true;
    _connect();
  }

  /// The app has come back to the screen (Matt, 2026-11-16: "fix delivery"): a connection that is down is tried now,
  /// not at the end of its wait, and one held while the app was away for [stale] or longer is made again, since the
  /// phone may have let it die without saying so (the relay server would hand it messages that go nowhere).
  void nudge({Duration away = Duration.zero, Duration stale = const Duration(seconds: 45)}) {
    if (!_wanted) return;
    // Refused for its pass phrase: waits for one to be given ([passAgain]), not for the app to come back.
    if (passRefused != null && _ws == null) return;
    if (_ws != null && away < stale) return;
    _again?.cancel();
    _tries = 0;
    if (_ws != null) _drop('made again after the app was away');
    unawaited(_connect());
  }

  /// A pass phrase was given (or changed) for this relay: tried at once, wherever the route stood.
  void passAgain() {
    passRefused = null;
    if (!_wanted) return;
    _again?.cancel();
    _tries = 0;
    if (_ws != null) _drop('made again with a pass phrase');
    unawaited(_connect());
  }

  @override
  Future<void> stop() async {
    _wanted = false;
    _again?.cancel();
    _drop('stopped');
    state.value = CarrierState.off;
  }

  /// Lets the connection go: everything waiting for an answer fails with [why], each room joined is said to be
  /// closed, and nobody is known to be here.
  void _drop(String why, {bool replaced = false}) {
    final ws = _ws;
    _ws = null;
    _ready = false;
    ws?.close().catchError((_) => null);
    for (final c in _sent.values) {
      if (!c.isCompleted) c.completeError(CarrierError(why));
    }
    _sent.clear();
    _sentTo.clear();
    for (final c in _joining.values) {
      if (!c.isCompleted) c.completeError(CarrierError(why));
    }
    _joining.clear();
    for (final room in _joined.keys) {
      _rooms.add(RoomEvent(room, closed: true, replaced: replaced));
    }
    // Lost: nobody is known to be here until the hub says again.
    if (here.value.isNotEmpty || away.value.isNotEmpty || busy.value.isNotEmpty) {
      here.value = const {};
      away.value = const {};
      busy.value = const {};
      presence.value++;
    }
  }

  /// Dials the hub. Signing in follows in [_said], when the hub says hello.
  Future<void> _connect() async {
    if (!_wanted || _ws != null) return;
    // Refused for its pass phrase, wrong or not given: not dialled again, the route started anew or not, until one is
    // given ([passAgain]).
    if (passRefused == 'wrong' || passRefused == 'needed') {
      state.value = CarrierState.down;
      return;
    }
    state.value = CarrierState.connecting;
    final HubLink ws;
    try {
      ws = await _dial(url);
    } catch (e) {
      _lost('The relay server could not be reached');
      return;
    }
    if (!_wanted) {
      ws.close().catchError((_) => null);
      return;
    }
    _ws = ws;
    ws.said.listen((data) => _said(ws, data), onDone: () => _gone(ws), onError: (_) => _gone(ws), cancelOnError: true);
  }

  /// The connection [ws] ended; nothing where it is no longer the one in use.
  void _gone(HubLink ws) {
    if (!identical(_ws, ws)) return;
    // Closed by the hub for a newer connection of this same device (relay/lib/hub.dart, 4409): a second window of the
    // app, started from the same folder (GMFB-47). Said to the rooms, so a call is left and not mended.
    _drop('the connection was lost', replaced: ws is HubLinkEnd && (ws as HubLinkEnd).closeCode == 4409);
    _lost('The connection to the relay server was lost');
  }

  /// The connection is down for [why]. Dialled again by itself: sooner at first, then every half minute; or once,
  /// after [again], for a refused pass phrase that was given too often (`busy`), and not at all for one that was wrong
  /// or not given ([passRefused]), until [nudge].
  void _lost(String why, {Duration? again}) {
    if (!_wanted) return;
    problem = why;
    state.value = CarrierState.down;
    _again?.cancel();
    if (passRefused != null) {
      if (again != null) _again = Timer(again, _connect);
      return;
    }
    // Sooner at first, then every half minute: a phone that is offline for hours does not hammer at it.
    final wait = _retry * (_tries < 4 ? 1 << _tries : 10);
    _tries++;
    _again = Timer(wait, _connect);
  }

  /// What the hub said on [ws]: bytes are a packet, by their first byte (1 to this account, 2 in a room, 4 a room's
  /// reaction); words are the hub's own, as JSON.
  Future<void> _said(HubLink ws, Object data) async {
    if (!identical(_ws, ws)) return;
    if (_ready) heardAt = _now().millisecondsSinceEpoch;
    if (data is List<int>) {
      if (data.length > 17 && data[0] == 1) {
        _arrived.add(Arrived(id, Uint8List.fromList(data.sublist(17)), from: NetCrypto.hex(data.sublist(1, 17))));
      } else if (data.length > 18 && data[0] == 7 && data.length > 18 + data[17]) {
        // What this account sent its own name, with the device that sent it, as the hub vouches (asked for with `stamp`
        // in the hello; relay/lib/hub.dart toPeerFromDevice): a history goes only to the device that asked (GMFB-53).
        final n = data[17];
        String? device;
        try {
          device = utf8.decode(data.sublist(18, 18 + n));
        } catch (_) {}
        _arrived.add(Arrived(id, Uint8List.fromList(data.sublist(18 + n)), from: NetCrypto.hex(data.sublist(1, 17)), device: device));
      } else if (data.length > 33 && data[0] == 2) {
        _roomPackets.add((room: NetCrypto.hex(data.sublist(1, 17)), from: NetCrypto.hex(data.sublist(17, 33)), bytes: Uint8List.fromList(data.sublist(33))));
      } else if (data.length > 33 && data[0] == 4) {
        // A reaction in a room (relay/lib/hub.dart toRoomReaction): nothing but a reaction is taken from one.
        _roomReactions.add((room: NetCrypto.hex(data.sublist(1, 17)), from: NetCrypto.hex(data.sublist(17, 33)), bytes: Uint8List.fromList(data.sublist(33))));
      }
      return;
    }
    Map<String, dynamic> m;
    try {
      m = (jsonDecode(data as String) as Map).cast<String, dynamic>();
    } catch (_) {
      return;
    }
    if (m['hello'] is String && !_ready) {
      takesReactions = m['react'] == true;
      relay = HubRelay.from(m['relay']);
      hosted = m['hosted'] == true;
      asksPass = m['pass'] == true;
      // A hosted relay's address names the relay: another answering there is not signed in to (found in the second
      // review, 2026-11-23: nothing checked it).
      final named = GhostRelayAddress.parse(url);
      if (named != null && !HubRelay.proves(m, named)) {
        _drop('wrong relay');
        _lost(wrongRelayWords);
        return;
      }
      // The hub's number, signed: only the holder of this install's key connects under its name. To a hub that takes
      // it, bound to the host dialled ([greetingV2]); to one from before, as ever.
      final v2 = m['v2'] == true;
      final nonce = NetCrypto.unhex(m['hello'] as String);
      final host = hostOf(url);
      final sig = await signer.sign(v2 ? signedV2(host, nonce) : [...utf8.encode(greeting), ...nonce]);
      // A hub that asks for a pass phrase is shown a proof of it for this connection ([HubPass]), where one was given;
      // with none it is told nothing, and says so.
      // Made with the relay's own salt; a hub that names none, or one that can't be, is given none.
      final phrase = asksPass ? pass?.call()?.trim() : null;
      final salt = m['salt'];
      String? proof;
      if (phrase != null && phrase.isNotEmpty && HubPass.saltOk(salt)) {
        try {
          proof = HubPass.proof(await HubPass.keyOf(phrase, salt as String), nonce, signer.id);
        } catch (_) {}
      }
      if (!identical(_ws, ws)) return;
      ws.say(jsonEncode({'id': signer.id, 'key': base64Encode(signer.publicKey), 'sig': base64Encode(sig), if (v2) 'v': 2, if (v2) 'host': host, if (device.isNotEmpty) 'device': device, if (device.isNotEmpty) 'stamp': true, if (_hubMode != 'online') 'mode': _hubMode, 'pass': ?proof}));
    } else if (m.containsKey('ok') && !_ready) {
      if (m['ok'] != true) {
        _drop('refused');
        final kind = m['pass'];
        if (kind is String) {
          // The pass phrase: not tried again by itself, but once a phrase is given (or, too many wrong lately, a while
          // on): each try with the same would be refused the same, and count.
          passRefused = kind;
          // Busy: as long as the relay says that try would wait (`"wait"`, seconds), a minute to an hour; ten minutes
          // where it doesn't say.
          final wait = m['wait'];
          final busyFor = wait is int && wait > 0 ? Duration(seconds: wait.clamp(60, 3600)) : passBusyWait;
          passBusyFor = kind == 'busy' ? busyFor : null;
          _lost(m['err'] is String ? m['err'] as String : 'This relay asks for a pass phrase.', again: kind == 'busy' ? busyFor : null);
          return;
        }
        _lost('The relay server refused this app: ${m['err'] ?? 'no reason given'}');
        return;
      }
      _ready = true;
      _tries = 0;
      problem = null;
      passRefused = null;
      passBusyFor = null;
      signedInAt = heardAt = _now().millisecondsSinceEpoch;
      final relayNow = m['now'], since = m['since'];
      relayStartedAt = relayNow is int && since is int && since <= relayNow ? signedInAt - (relayNow - since) : 0;
      // Said before anyone hears the route is up, so nothing can be sent ahead of it.
      try {
        for (final first in onSignIn?.call() ?? const <Map<String, Object?>>[]) {
          ws.say(jsonEncode(first));
        }
      } catch (_) {}
      // Before the route is up: whoever acts on its coming up has the helpers this hub names.
      final named = m['helpers'];
      _helpers.value = List.unmodifiable([
        if (named is List)
          for (final h in named.take(4 * mostHelpers))
            if (h is String && h.length <= longestHelper && h.startsWith('https://')) h,
      ].take(mostHelpers));
      state.value = CarrierState.up;
      if (_watched.isNotEmpty) ws.say(jsonEncode({'watch': _watched.toList()}));
      if (_awaySaid) ws.say(jsonEncode({'away': true}));
      if (_push != null) ws.say(jsonEncode({'push': _push}));
      for (final e in _joined.entries) {
        ws.say(jsonEncode({'join': e.key, 'token': e.value, 'ro': ?_readOnly[e.key]}));
      }
      for (final e in _looked.entries) {
        ws.say(jsonEncode({'look': e.key, 'token': e.value}));
      }
    } else if (m['dir'] is String) {
      // Home records have a listener of their own; a relay from before answers them "no such thing", if at all.
      final dir = m['dir'], about = m['about'];
      (dir == 'home' || dir == 'home?' || (dir == 'err' && (about == 'home' || about == 'home?')) ? _homes : _handles).add(m);
    } else if (m.containsKey('ack')) {
      final to = _sentTo.remove(m['ack']);
      if (to != null) {
        refusedWhy.remove(to);
        if (m['waiting'] == true) {
          waitingFor.add(to);
        } else {
          waitingFor.remove(to);
        }
        if (m['fed'] == true) {
          _crossed.add(to);
        } else {
          _crossed.remove(to);
          if (m['here'] != true) onKeptHere?.call(to);
        }
      }
      _sent.remove(m['ack'])?.complete(m['here'] == true ? Handed.passed : Handed.held);
    } else if (m.containsKey('nak')) {
      final to = _sentTo.remove(m['nak']);
      if (m['err'] == 'home') onNoHome?.call();
      final why = switch (m['err']) {
        'full' => 'their relay, or yours, is holding too much for them already',
        'far' => 'their relay can\'t be reached from yours',
        'refused' => 'their relay would not take it',
        'home' => 'your relay didn\'t know where you live yet; it has been told, and it goes again',
        'busy' => 'you have sent a lot to other relays just now; it goes again in a while',
        _ => 'the relay server would not take it',
      };
      if (to != null) {
        waitingFor.remove(to);
        refusedWhy[to] = why;
        while (refusedWhy.length > 500) {
          refusedWhy.remove(refusedWhy.keys.first);
        }
      }
      _sent.remove(m['nak'])?.completeError(CarrierError(why));
    } else if (m['room'] is String && m['look'] is List) {
      // Who is in a room this install looks at without being in it.
      final room = m['room'] as String;
      final members = (m['look'] as List).cast<String>();
      looking[room] = members;
      _looks.add((room: room, members: members));
    } else if (m['room'] is String) {
      final room = m['room'] as String;
      if (m.containsKey('ok')) {
        final c = _joining.remove(room);
        if (m['ok'] == true) {
          final members = (m['members'] as List? ?? const []).cast<String>();
          if (m['ice'] is Map) callRelay = (m['ice'] as Map).cast<String, Object>();
          c?.complete(members);
          _rooms.add(RoomEvent(room, members: members));
        } else {
          _joined.remove(room);
          c?.completeError(CarrierError(m['err'] == 'full' ? 'that room is full' : 'the room would not let this app in'));
        }
      } else if (m['came'] is String) {
        _rooms.add(RoomEvent(room, came: m['came'] as String));
      } else if (m['went'] is String) {
        _rooms.add(RoomEvent(room, went: m['went'] as String));
      }
    } else if (m['here'] is List) {
      // Who, of those asked about, is connected now; then each as they come and go. (A room's coming and going
      // names its room, and is the branch above.) With them, who has the app put away, and when those not here were
      // last there (a hub before 2026-11-17 says neither).
      final now = (m['here'] as List).cast<String>();
      here.value = {...here.value, ...now};
      away.value = {...away.value.where((id) => !now.contains(id)), ...((m['away'] as List?) ?? const []).cast<String>()};
      busy.value = {...busy.value.where((id) => !now.contains(id)), ...((m['busy'] as List?) ?? const []).cast<String>()};
      (m['seen'] as Map?)?.forEach((id, at) {
        if (at is num) seen['$id'] = DateTime.fromMillisecondsSinceEpoch(at.toInt());
      });
      presence.value++;
    } else if (m['came'] is String) {
      here.value = {...here.value, m['came'] as String};
      away.value = {...away.value}..remove(m['came']);
      busy.value = {...busy.value}..remove(m['came']);
      presence.value++;
    } else if (m['went'] is String) {
      final id = m['went'] as String;
      here.value = {...here.value}..remove(id);
      away.value = {...away.value}..remove(id);
      busy.value = {...busy.value}..remove(id);
      seen[id] = m['at'] is num ? DateTime.fromMillisecondsSinceEpoch((m['at'] as num).toInt()) : DateTime.now();
      presence.value++;
    } else if (m['away'] is String) {
      // Someone watched put the app away, or came back to it.
      final id = m['away'] as String;
      if (m['is'] == true) {
        away.value = {...away.value, id};
        if (m['at'] is num) seen[id] = DateTime.fromMillisecondsSinceEpoch((m['at'] as num).toInt());
      } else {
        away.value = {...away.value}..remove(id);
      }
      presence.value++;
    } else if (m['busy'] is String) {
      // Someone watched chose Busy, or stopped (GMFB-34).
      final id = m['busy'] as String;
      busy.value = m['is'] == true ? {...busy.value, id} : ({...busy.value}..remove(id));
      presence.value++;
    }
  }

  Map<String, Object?>? _push;

  /// How the hub may wake this app when something is held for it and it is closed: an iPhone's Apple push token
  /// (`{'apns': hex, 'sandbox': bool}`; relay/lib/pushes.dart). Said on every sign-in, so a hub that restarted or
  /// lost it hears it again; null tells it to forget.
  Map<String, Object?>? get push => _push;
  set push(Map<String, Object?>? value) {
    final had = _push;
    _push = value;
    final ws = _ws;
    if (_ready && ws != null && (value != null || had != null)) ws.say(jsonEncode({'push': value}));
  }

  /// A hub reaches anyone: someone who is not connected to it is kept for.
  @override
  bool reaches(Peer peer) => _ready;

  /// Hands [packet] to the hub for [peer]: passed on where they are connected, held for them where they aren't.
  /// Fails where the hub refuses it or says nothing for eight seconds.
  @override
  Future<Handed> send(Peer peer, Uint8List packet) {
    final ws = _ws;
    if (ws == null || !_ready) throw CarrierError('not connected to the relay server');
    final seq = _seq = (_seq + 1) & 0x7fffffff;
    final head = ByteData(5)
      ..setUint8(0, 1)
      ..setUint32(1, seq);
    final done = _sent[seq] = Completer<Handed>();
    _sentTo[seq] = peer.id;
    ws.say([...head.buffer.asUint8List(), ...NetCrypto.unhex(peer.id), ...packet]);
    return done.future.timeout(const Duration(seconds: 8), onTimeout: () {
      _sent.remove(seq);
      _sentTo.remove(seq);
      throw CarrierError('the relay server did not answer');
    });
  }

  /// Asks to be told when these names come and go ([here]).
  void watch(Iterable<String> ids) {
    final fresh = ids.where(_watched.add).toList();
    if (fresh.isNotEmpty && _ready) _ws?.say(jsonEncode({'watch': fresh}));
  }

  /// Joins a room, giving who is in it. It is joined again by itself after the route is lost and comes back.
  ///
  /// Asked before the relay server is connected (a circle's spaces are held as the app starts), the room is joined as
  /// soon as it is, as every room this install is in is on reconnecting, and this answers then (Matt, 2026-11-18: a
  /// circle's members' messages seen on no device: each room asked for too early was never joined, so nothing came
  /// from it and what was written in it went nowhere). Unanswered once connected, it stays asked for, and is asked again
  /// on the next connection.
  ///
  /// [ro]: a circle's read-only space's room, bound to its owner's key (relay/lib/hub.dart; lib/circles/welcome.dart),
  /// said with each join.
  Future<List<String>> join(String room, String token, {Map<String, Object?>? ro}) {
    _joined[room] = token;
    if (ro != null) {
      _readOnly[room] = ro;
    } else {
      _readOnly.remove(room);
    }
    final done = _joining[room] ??= Completer<List<String>>();
    final ws = _ws;
    if (ws == null || !_ready) return done.future;
    ws.say(jsonEncode({'join': room, 'token': token, 'ro': ?ro}));
    return done.future.timeout(const Duration(seconds: 8), onTimeout: () {
      if (identical(_joining[room], done)) _joining.remove(room);
      throw CarrierError('the relay server did not answer');
    });
  }

  /// Leaves [room]; it is not joined again on reconnecting.
  void leave(String room) {
    _readOnly.remove(room);
    if (_joined.remove(room) != null && _ready) _ws?.say(jsonEncode({'leave': room}));
  }

  /// What each read-only room this install is in was joined with ([join]'s `ro`), to join it so again on reconnecting.
  final Map<String, Map<String, Object?>> _readOnly = {};

  /// Tells the relay a read-only room's newer admin list ([grants]: `gv`, `g`, `gs`), kept for the next join too.
  void anchorRoom(String room, Map<String, Object?> grants) {
    final ro = _readOnly[room];
    if (ro == null) return;
    _readOnly[room] = {...ro, ...grants};
    if (_ready) _ws?.say(jsonEncode({'anchor': room, ...grants}));
  }

  /// Sends a packet to everyone else in a room this install is in.
  ///
  /// [keep]: the hub keeps it too, sealed as it is, for whoever joins the room later (relay/lib/hub.dart toRoomKept):
  /// what a space's members wrote reaches a phone that was closed at the time.
  void sendRoom(String room, Uint8List packet, {bool keep = false}) {
    if (!_ready || !_joined.containsKey(room)) throw CarrierError('not in that room');
    _ws?.say([keep ? 3 : 2, ...NetCrypto.unhex(room), ...packet]);
  }
}
