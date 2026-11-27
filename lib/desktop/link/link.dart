import 'dart:async';

import 'package:flutter/foundation.dart';

import 'crypto.dart';
import 'relay_socket.dart';
import 'session.dart';

/// Somewhere the phone may be listening on the local network.
@immutable
class Peer {
  const Peer(this.host, this.port);
  final String host;
  final int port;

  /// `192.168.1.20:47811`, or `[fe80::1]:47811`.
  static Peer? parse(String text) {
    final t = text.trim();
    final at = t.lastIndexOf(':');
    if (at <= 0) return null;
    final port = int.tryParse(t.substring(at + 1));
    var host = t.substring(0, at);
    if (host.startsWith('[') && host.endsWith(']')) host = host.substring(1, host.length - 1);
    if (port == null || port < 1 || port > 65535 || host.isEmpty) return null;
    return Peer(host, port);
  }

  @override
  bool operator ==(Object other) => other is Peer && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);

  @override
  String toString() => host.contains(':') ? '[$host]:$port' : '$host:$port';
}

/// What finds phones announcing themselves on the local network: Bonjour on a Mac (lib/desktop/platform.dart).
abstract class PeerFinder {
  List<Peer> get current;

  /// Told each time what is found changes.
  set onChange(void Function()? listener);
  void start();
  void stop();
}

/// The phone this Mac is paired with, as the Mac keeps it.
class PairedPhone {
  PairedPhone({required this.id, required this.name, required this.key, required this.mode, required this.relay, required this.since, this.host, this.port});
  /// The pairing's id, made from its key ([DeskCrypto.id]): what the Mac says first so the phone knows which key.
  final String id;
  String name;

  /// The pairing's key: with it, and only with it, the two can talk. Kept in the Keychain (lib/desktop/store.dart).
  final Uint8List key;

  /// both, local, relay.
  String mode;

  /// The relay's address as it was at pairing; empty where the pairing has none.
  final String relay;
  final DateTime since;

  /// Where the phone was reached on the local network last, tried first the next time.
  String? host;
  int? port;
}

/// Where the pairing is kept between runs.
abstract class LinkStore {
  Future<PairedPhone?> load();
  Future<void> save(PairedPhone phone);
  Future<void> clear();
}

/// A pairing while it is being made: the QR code is on the screen, then the six digits, then it is done.
class PairingAttempt {
  PairingAttempt({required this.offer, required this.keyPair}) : started = DateTime.now();
  /// What the QR code says, and the key pair whose public half is in it.
  final DeskOffer offer;
  final DeskKeyPair keyPair;
  final DateTime started;

  /// showing (the QR code, waiting for the phone), code (both show six digits), done, failed.
  String phase = 'showing';

  /// The six digits, once the phone has connected.
  String? code;
  String phoneName = '';

  /// How the two will connect from then on: what the Mac offered until the phone says otherwise.
  late String mode = offer.mode;

  /// "They match" was said here, and on the phone.
  bool mine = false;
  bool theirs = false;
  String? error;

  /// The code has been on the screen longer than a pairing may take.
  bool get expired => DateTime.now().difference(started) > PhoneLink.pairingLife;
}

/// The Mac's link to the phone (docs/desktop.md): pairing with it, staying connected to it, asking it things.
///
/// **Which way.** With the pairing set to both, the local network is tried first: the places the phone may be
/// listening (where it was last, what Bonjour finds, an address given by hand), one after another. Only when none
/// answers is a connection made through the relay, which is held ready meanwhile. While connected through the relay
/// the local network is tried again now and then, and taken when it answers. Local only never dials the relay;
/// relay only never looks on the network.
///
/// It is the same over either: a [LinkSession], sealed under the pairing's key.
class PhoneLink extends ChangeNotifier {
  PhoneLink({required this.store, required this.name, this.app = '', this.finder, List<Peer> given = const []}) : given = List.of(given);

  final LinkStore store;

  /// This Mac's name, as the phone shows it.
  final String name;

  /// Said to the phone as each connection opens, beside the name.
  final String app;
  final PeerFinder? finder;

  /// Addresses given by hand: tried first, before what is remembered and what Bonjour finds.
  List<Peer> given;

  /// How long a pairing code stays good while it waits for the phone.
  static Duration pairingLife = const Duration(minutes: 10);

  /// How often the phone is looked for while there is no connection, and how often the local network is tried
  /// again while the relay carries the connection. Shorter under test.
  static Duration lookEvery = const Duration(seconds: 3);
  static Duration upgradeEvery = const Duration(seconds: 15);

  /// How often a live connection is asked whether the phone is still there.
  static Duration pingEvery = const Duration(seconds: 20);

  /// How long one address on the local network is given to answer, and how long the phone has to say hello back.
  static Duration connectTimeout = const Duration(milliseconds: 1500);
  static Duration helloTimeout = const Duration(seconds: 8);

  /// The phone paired with, and the pairing being made; either may be null.
  PairedPhone? phone;
  PairingAttempt? attempt;

  /// How the phone is connected now: local, relay, or null when it is not.
  String? get via => shownVia ?? (_session?.live == true ? _session!.transport.via : null);

  /// For pictures of the screens (test/desk_screens_test.dart), which have no phone to be connected to.
  @visibleForTesting
  String? shownVia;

  /// Connected to the paired phone, and not in the middle of pairing.
  bool get online => via != null && attempt == null;

  /// The phone answered that it does not have this pairing: it was unpaired there while the Mac was away.
  bool refused = false;

  /// What the phone says happened: `changed` with a conversation.
  final events = StreamController<({String name, Map<String, dynamic> args})>.broadcast();

  /// Fires each time a connection to the paired phone comes up.
  final connected = StreamController<void>.broadcast();

  LinkSession? _session;

  /// Where on the local network the connection now open was made; null through the relay.
  Peer? _sessionPeer;

  /// The connection to the relay, held ready whether or not a session runs over it ([_holdRelay]).
  RelaySocket? _relay;
  Timer? _looker;
  Timer? _pinger;

  /// One look at a time: a look asked for during another runs straight after it.
  bool _looking = false;
  bool _lookAgain = false;
  bool _disposed = false;

  /// The mode was changed here while the phone was away, and it has not been told yet.
  bool _modeDirty = false;
  DateTime _lastUpgradeTry = DateTime.fromMillisecondsSinceEpoch(0);

  /// The relay is not dialled again before this; [_relayFailures] counts the drops in a row that set it.
  DateTime _relayRetryAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _relayFailures = 0;

  /// Reads the pairing kept and starts looking for the phone, on a timer and whenever Bonjour finds something.
  Future<void> start() async {
    phone = await store.load();
    finder?.onChange = look;
    finder?.start();
    _looker = Timer.periodic(lookEvery, (_) => look());
    _pinger = Timer.periodic(pingEvery, (_) => _ping());
    notifyListeners();
    look();
  }

  @override
  void dispose() {
    _disposed = true;
    _looker?.cancel();
    _pinger?.cancel();
    finder?.onChange = null;
    finder?.stop();
    _session?.close();
    _relay?.close();
    events.close();
    connected.close();
    super.dispose();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  // --- what is being connected to ---------------------------------------------------------------------------------------

  /// While a pairing is being made, what is connected to is the attempt's offer (its mode, relay and temporary
  /// channel); otherwise the paired phone's.
  bool get _pairing => attempt != null && (attempt!.phase == 'showing' || attempt!.phase == 'code');
  String get _mode => _pairing ? attempt!.offer.mode : (phone?.mode ?? 'both');
  String get _relayBase => (_pairing ? attempt!.offer.relay : (phone?.relay ?? '')).trim();
  bool get _wantLocal => (_pairing || phone != null) && _mode != 'relay';
  bool get _wantRelay => (_pairing || phone != null) && _mode != 'local' && _relayBase.isNotEmpty;

  /// The relay's address with this pairing's channel at its end; null where the relay is not to be used.
  String? get _relayUrl {
    if (!_wantRelay) return null;
    final channel = _pairing ? DeskCrypto.pairingChannel(attempt!.offer.secret) : DeskCrypto.relayChannel(phone!.key);
    return '${_relayBase.replaceAll(RegExp(r'/+$'), '')}/$channel';
  }

  /// Everywhere the phone may be listening, the likeliest first.
  List<Peer> get _candidates {
    final remembered = phone?.host != null && phone?.port != null ? Peer(phone!.host!, phone!.port!) : null;
    return <Peer>{...given, ?remembered, ...?finder?.current}.toList();
  }

  // --- staying connected ------------------------------------------------------------------------------------------------

  /// Looks for the phone now: called on a timer, when Bonjour finds something, and when anything changes.
  Future<void> look() async {
    if (_disposed) return;
    if (_looking) {
      _lookAgain = true;
      return;
    }
    _looking = true;
    try {
      final a = attempt;
      if (a != null && a.phase == 'showing' && a.expired) {
        a.phase = 'failed';
        a.error = 'The code ran out. Show a new one.';
        _changed();
      }
      _holdRelay();
      if (!_pairing && phone == null) return;
      final live = _session?.live == true;
      if (!live) {
        // The local network first; the relay only when nothing there answers.
        if (_wantLocal && await _tryLocal()) return;
        if (_wantRelay) await _tryRelay();
      } else if (_session!.transport.via == 'relay' && _wantLocal && DateTime.now().difference(_lastUpgradeTry) >= upgradeEvery) {
        // Through the relay for now: the local network is tried again, and taken when it answers.
        _lastUpgradeTry = DateTime.now();
        await _tryLocal();
      }
    } finally {
      _looking = false;
      if (_lookAgain) {
        _lookAgain = false;
        scheduleMicrotask(look);
      }
    }
  }

  /// Keeps the connection to the relay as it should be: open while the pairing may use it, closed when it may not.
  void _holdRelay() {
    final url = _relayUrl;
    final had = _relay;
    if (had != null && (had.closed || had.url != url)) {
      if (had.closed && had.url == url) {
        // It dropped (or the relay is not there): tried again after a wait that grows to a minute.
        _relayFailures++;
        // 2, 4, 8, 16, then 32 seconds. Under test, where looks are less than a second apart, one look's wait.
        final wait = Duration(seconds: (2 << (_relayFailures.clamp(1, 5) - 1)).clamp(2, 60));
        _relayRetryAt = DateTime.now().add(lookEvery < const Duration(seconds: 1) ? lookEvery : wait);
      }
      had.close();
      _relay = null;
    }
    if (url == null || _relay != null || DateTime.now().isBefore(_relayRetryAt)) return;
    final token = _pairing ? DeskCrypto.pairingToken(attempt!.offer.secret) : DeskCrypto.relayToken(phone!.key);
    final socket = RelaySocket(url: url, token: token, temp: _pairing, onChange: () {
      if (_relay?.joined == true) _relayFailures = 0;
      look();
    });
    _relay = socket;
    socket.connect();
  }

  /// Opens a session over [transport]: as a pairing (the offer's secret and a fresh key pair) while one is being
  /// made, else under the paired phone's key. Throws where the other end is not that phone.
  Future<LinkSession> _open(FrameTransport transport) async {
    final session = LinkSession(transport);
    final a = attempt;
    if (_pairing) {
      await session.open(id: DeskCrypto.pairingId(a!.offer.secret), pairing: a.keyPair, secret: a.offer.secret, name: name, app: app, timeout: helloTimeout);
    } else {
      await session.open(id: phone!.id, pairKey: phone!.key, name: name, app: app, timeout: helloTimeout);
    }
    return session;
  }

  /// Tries each place the phone may be listening, in turn; true once a session is open with one.
  Future<bool> _tryLocal() async {
    for (final peer in _candidates) {
      if (_disposed || (!_pairing && phone == null)) return false;
      try {
        final session = await _open(await TcpTransport.connect(peer.host, peer.port, timeout: connectTimeout));
        _adopt(session, peer);
        return true;
      } catch (_) {
        // Nothing there, or a phone that is not this one's (another copy of the app on the network): the next.
      }
    }
    return false;
  }

  /// Opens a session through the relay, once this side has joined the channel and the phone is on it too.
  Future<bool> _tryRelay() async {
    final relay = _relay;
    if (relay == null || !relay.joined || !relay.peer) return false;
    try {
      final session = await _open(relay.transport());
      _adopt(session, null);
      return true;
    } on LinkRefused catch (e) {
      // Only the phone holds the channel's token with this Mac: it is the phone saying the pairing is gone.
      if (e.why == 'unknown' && !_pairing && !refused) {
        refused = true;
        _changed();
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Makes [session] the connection in use, in place of any before it (which is told goodbye). In a pairing it
  /// brings the six digits; with a paired phone it brings the phone's name and mode, and where it was reached.
  void _adopt(LinkSession session, Peer? peer) {
    final old = _session;
    _session = session;
    _sessionPeer = peer;
    if (old != null && !old.closed) {
      old.event('bye');
      old.close();
    }
    refused = false;
    session.events.listen((e) => _onEvent(session, e.name, e.args));
    session.done.then((_) => _ended(session));
    final a = attempt;
    if (_pairing) {
      a!
        ..phase = 'code'
        ..code = DeskCrypto.code(session.key!)
        ..phoneName = '${session.ready['name'] ?? 'Your phone'}'
        ..mine = false
        ..theirs = false;
      final mode = session.ready['mode'];
      if (mode is String && DeskOffer.modes.contains(mode)) a.mode = mode;
    } else {
      final p = phone!;
      final said = session.ready['name'];
      if (said is String && said.isNotEmpty) p.name = said;
      if (peer != null) {
        p.host = peer.host;
        p.port = peer.port;
      }
      final mode = session.ready['mode'];
      if (_modeDirty) {
        // Changed here while the phone was away: the phone is told now.
        session.event('mode', {'mode': p.mode});
        _modeDirty = false;
      } else if (mode is String && DeskOffer.modes.contains(mode)) {
        p.mode = mode;
      }
      store.save(p);
      connected.add(null);
    }
    _changed();
  }

  /// The connection in use closed: the phone is looked for again in a moment. One already replaced is ignored.
  void _ended(LinkSession session) {
    if (!identical(_session, session)) return;
    _session = null;
    final a = attempt;
    if (a != null && a.phase == 'code') {
      // The phone went before both said the digits match: it may come back while the code lasts.
      a
        ..phase = 'showing'
        ..code = null
        ..mine = false
        ..theirs = false;
    }
    _changed();
    if (!_disposed) Timer(const Duration(milliseconds: 200), look);
  }

  Future<void> _ping() async {
    final session = _session;
    if (session == null || !session.live || _pairing) return;
    try {
      await session.request('ping', null, const Duration(seconds: 8));
    } catch (_) {
      // Silence: the connection is taken to be gone, and the phone is looked for again.
      if (identical(_session, session)) session.close();
    }
  }

  /// What the phone says without being asked. During a pairing's six digits: its mode, its "They match", its cancel.
  /// Otherwise: unpaired and a change of mode are dealt with here, and anything else goes out on [events].
  void _onEvent(LinkSession session, String name, Map<String, dynamic> args) {
    if (!identical(_session, session)) return;
    final a = attempt;
    if (a != null && a.phase == 'code') {
      switch (name) {
        case 'mode':
          final mode = args['mode'];
          if (mode is String && DeskOffer.modes.contains(mode)) a.mode = mode;
        case 'confirmed':
          a.theirs = true;
          _finishIfBoth();
        case 'cancel':
          a
            ..phase = 'failed'
            ..error = 'Pairing was cancelled on the phone.';
          session.close();
      }
      _changed();
      return;
    }
    switch (name) {
      case 'unpaired':
        _forget();
      case 'mode':
        final mode = args['mode'];
        final p = phone;
        if (p != null && mode is String && DeskOffer.modes.contains(mode)) {
          p.mode = mode;
          store.save(p);
          _changed();
          look();
        }
      default:
        if (!events.isClosed) events.add((name: name, args: args));
    }
  }

  /// Asks the paired phone for [method]. Throws [LinkDown] when it is not connected, [PhoneError] with its words
  /// when it would not.
  Future<dynamic> request(String method, [Map<String, dynamic>? args, Duration timeout = const Duration(seconds: 20)]) {
    final session = _session;
    if (session == null || !session.live || _pairing || phone == null) return Future.error(const LinkDown());
    return session.request(method, args, timeout);
  }

  // --- pairing ----------------------------------------------------------------------------------------------------------

  /// Starts a pairing: what the QR code shows is in what it returns. The phone is then looked for, by [mode].
  PairingAttempt beginPairing({required String mode, required String relay}) {
    _session?.close();
    final keyPair = DeskCrypto.newKeyPair();
    final a = PairingAttempt(
      offer: DeskOffer(key: keyPair.public, secret: DeskCrypto.randomBytes(16), name: name, mode: relay.trim().isEmpty ? 'local' : mode, relay: relay.trim()),
      keyPair: keyPair,
    );
    attempt = a;
    _relayRetryAt = DateTime.fromMillisecondsSinceEpoch(0);
    _changed();
    look();
    return a;
  }

  /// "They match", here.
  void confirmPairing() {
    final a = attempt;
    if (a == null || a.phase != 'code' || a.mine) return;
    a.mine = true;
    _session?.event('confirmed');
    _finishIfBoth();
    _changed();
  }

  /// Gives the pairing up from here: the phone is told where it is already showing the digits.
  Future<void> cancelPairing() async {
    final a = attempt;
    if (a == null) return;
    final session = _session;
    if (a.phase == 'code') session?.event('cancel');
    attempt = null;
    await session?.close();
    _changed();
    look();
  }

  /// The wizard has shown how the pairing ended.
  void pairingShown() {
    if (attempt?.phase == 'done' || attempt?.phase == 'failed') {
      attempt = null;
      _changed();
    }
  }

  /// Once "They match" was said on both: the session's key becomes the pairing's, and the phone is kept.
  void _finishIfBoth() {
    final a = attempt;
    final session = _session;
    if (a == null || a.phase != 'code' || !a.mine || !a.theirs || session == null) return;
    final key = session.key!;
    final p = PairedPhone(id: DeskCrypto.id(key), name: a.phoneName, key: key, mode: a.mode, relay: a.offer.relay, since: DateTime.now(), host: _sessionPeer?.host, port: _sessionPeer?.port);
    phone = p;
    a.phase = 'done';
    store.save(p);
    if (session.transport.via == 'local' && p.mode != 'relay') {
      // Made over the local network: the connection goes on as the paired phone's, as the phone takes it to.
      connected.add(null);
      look();
      return;
    }
    // Made through the relay, on a channel that lasts ten minutes (or made locally for a pairing that is to use
    // the relay alone): the connection is let go, a moment after "They match" has gone out on it, and the phone is
    // connected to again as the paired phone it now is, on the pairing's own channel.
    _session = null;
    Timer(const Duration(milliseconds: 250), () async {
      await session.close();
      look();
    });
  }

  // --- the pairing, once made ---------------------------------------------------------------------------------------------

  /// How the two connect: both, local, relay. The phone is told, now or when it is next reached.
  Future<void> setMode(String mode) async {
    final p = phone;
    if (p == null || !DeskOffer.modes.contains(mode) || (mode != 'local' && p.relay.isEmpty)) return;
    p.mode = mode;
    await store.save(p);
    final session = _session;
    if (session != null && session.live) {
      session.event('mode', {'mode': mode});
      // A connection the new choice does not allow is let go.
      if ((mode == 'local' && session.transport.via == 'relay') || (mode == 'relay' && session.transport.via == 'local')) session.close();
    } else {
      _modeDirty = true;
    }
    _changed();
    look();
  }

  /// Unpairs from this side: the phone is told if it is reachable, the relay is told to forget the channel, and the
  /// key is deleted here.
  Future<void> unpair() async {
    if (phone == null) return;
    // Nothing is looked for from here on: the connections are taken aside, used to say goodbye, and closed.
    final session = _session;
    final relay = _relay;
    _session = null;
    _relay = null;
    phone = null;
    refused = false;
    _modeDirty = false;
    await store.clear();
    if (session != null && session.live) session.event('unpaired');
    if (relay != null && relay.joined) relay.forget();
    _changed();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await session?.close();
    await relay?.close();
  }

  /// The phone said it has unpaired: the pairing is deleted here and the connections closed, with nothing said back.
  Future<void> _forget() async {
    phone = null;
    refused = false;
    _modeDirty = false;
    await store.clear();
    await _session?.close();
    await _relay?.close();
    _relay = null;
    _changed();
  }
}
