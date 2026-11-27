import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../carrier.dart';
import '../crypto.dart';
import '../hub_carrier.dart' show HubCarrier;
import '../packet.dart';
import 'node.dart';
import 'p2p.dart';

/// The direct route (docs/OPEN_NETWORK.md, section 2): packets straight between this device and the devices of its
/// own account and its friends, with no server in between. It comes after the relay's hub (Switchboard.order): a way
/// through when the relay can't carry something. Who those devices are, and when the node runs, is [P2p]'s; this is
/// the carrying.
///
/// **Sending.** A packet goes to every device a card is held for (this account's own other devices where the peer
/// is this account), each on a stream that is open, else dialled by where the device last said it was, with
/// [P2pPolicy.dialFor] for all of it. Where something else carries envelopes and no stream is open, the device is
/// asked to meet as well ([P2p.meet]) and dialled again when its answer says where it is now. Passed as soon as one
/// device took it, while the others are still tried; where none did it throws and the switchboard goes on. Nothing is
/// ever kept. A device that could not be reached is not dialled again for [P2pPolicy.redialAfter], so what is sent
/// meanwhile is not held up by it.
///
/// **Whose device it is.** A card is an account's word that a node is its device, not the node's own (card.dart). So a
/// stream opens with each end's nonce, then each end's proof, the one that dialled first (once the other's nonce has
/// come) and the other once that proof checks out:
///
///     [0][2][a nonce: 16 random bytes]
///     [0][3][HMAC-SHA256(link key, "ghost-p2p link v2\n" | from account (16) | from node (32) | to account (16) |
///            to node (32) | the other end's nonce (16) | this end's (16))]
///
/// under a key made from what the two accounts seal their packets with ([P2p.linkKey]), which only their devices hold.
/// Both accounts are in it, in the order of who is proving to whom: both ends of a pair hold the pair's key, so a proof
/// without them showed only "holds the key", and a friend's card naming a device of this account's own made two of its
/// devices link with each other "as his" (second review, S2). The node ids are the ones the core's handshake vouched
/// for, and the nonces make each proof good for its own stream alone. Until the proof has come, nothing is sent on the
/// stream and nothing taken from it; one whose proof is not that of an account whose card names the node is closed. So
/// a packet for someone only ever goes to a device that holds their key and proved to be theirs, and what arrives is
/// vouched for ([Arrived.from]) as the hub's stamp is.
///
/// **Arriving.** After the proof every frame is a packet, handed on as it came. A stream from a node no card is held
/// for is closed, as is one that sends a frame longer than a packet may be, and one with nothing said on it for
/// [P2pPolicy.quiet].
class P2pCarrier implements Carrier, LiveLinks {
  P2pCarrier(this.p2p) {
    _opened = p2p.node.opened.listen(_adopt, onError: (Object _) {});
  }

  final P2p p2p;

  /// The longest packet carried, each way: the hub's, so a packet made for one route fits the other.
  static const maxPacket = HubCarrier.maxPacket;

  /// The most proved streams held with one node: one newly proved takes the place of the oldest. And the most not yet
  /// proved: a newer one takes the place of the oldest of those, and never of one that has proved whose it is.
  static const mostLines = 2, mostProving = 2;

  /// The most streams taken from one node in a minute; one opened beyond that is closed at once, unanswered (second
  /// review, M2).
  static const opensAMinute = 10;

  /// The least time a frame is given to go, however little is left of a send's: a real core's add across FFI is never
  /// instant (second review, S11).
  static const putAtLeast = Duration(seconds: 1);

  /// What one stream may bring in a while, and one account's devices together: so many frames at once, and so many
  /// more each second after. What comes beyond is dropped and counted ([dropped]), never passed on (second review,
  /// S12): a packet that matters is sent again until it is answered.
  static const lineBurst = 100, linePerSecond = 10, accountBurst = 150, accountPerSecond = 15;

  /// How many frames were dropped for coming faster than [lineBurst] and [accountBurst] let them.
  int dropped = 0;

  static final _words = utf8.encode('ghost-p2p link v2\n');
  static const _mark = 0, _nonceMark = 2, _proofMark = 3, _nonceLength = 16;

  /// The route's name to the switchboard and in what is kept (`net_off`, Net.directName), what it is called, and what
  /// it is, in words: the same for Settings › Routes' row before the route is made (Direct switched off) as after.
  static const routeId = 'p2p', label = 'Direct';

  /// What switching Direct on means, said on its row before it is on (Matt's brief, 2026-11-23): who is told where this
  /// device is, who learns its network address, and what a link helper sees.
  static const aboutWords =
      'Straight between your devices and your friends\', for when the relay server can\'t carry something. Their devices learn this device\'s network address, and nobody else is told it. A link helper sees which devices link and how much they send, never who they are or what is said.';

  @override
  String get id => routeId;
  @override
  String get name => label;
  @override
  String get about => aboutWords;
  @override
  CarrierTraits get traits => CarrierTraits(maxPacket: maxPacket, ackWait: p2p.policy.ackWait);
  @override
  final ValueNotifier<CarrierState> state = ValueNotifier(CarrierState.off);
  @override
  String? problem;

  final _arrived = StreamController<Arrived>.broadcast();
  @override
  Stream<Arrived> get arrived => _arrived.stream;

  /// The listening to streams other devices open, and what is under way with each node, by node id.
  StreamSubscription<P2pStream>? _opened;
  final Map<String, _Node> _nodes = {};

  /// What each account's devices may still bring now ([accountBurst]); none is kept of someone this device no longer
  /// links with.
  final Map<String, _Bucket> _buckets = {};
  bool _wanted = false;

  @override
  Future<void> start() async {
    _wanted = true;
    p2p.setOn(true);
    restate();
  }

  @override
  Future<void> stop() async {
    _wanted = false;
    closeAll();
    p2p.setOn(false);
    restate();
  }

  /// Ready while Direct is on and what is kept has been read; a phone's node being down is ready too, since it is
  /// started for a send. Down only where the node could not start.
  void restate() {
    final next = !_wanted || p2p.wiped ? CarrierState.off : !p2p.loaded ? CarrierState.connecting : p2p.failed ? CarrierState.down : CarrierState.up;
    problem = next == CarrierState.down ? p2p.problem : null;
    state.value = next;
  }

  /// Direct is on, and a good card is held for one of their devices.
  @override
  bool reaches(Peer peer) => _wanted && p2p.loaded && p2p.mayLink(peer.id) && p2p.devicesOf(peer.id).isNotEmpty;

  // --- streams ---------------------------------------------------------------------------------------------------------

  /// How many streams are open, proved or not: a phone's node stops some time after the last closes.
  int get lines => _nodes.values.fold(0, (n, node) => n + node.lines.length);

  /// The devices linked now, each with whose it proved to be and how the path to it stands (Settings › Routes).
  List<({String account, String nodeId, P2pPathKind kind})> get links => [
        for (final e in _nodes.entries)
          for (final account in {for (final l in e.value.lines) ?l.account})
            (account: account, nodeId: e.key, kind: _pathTo(e.key)),
      ];

  /// How the path to [nodeId] stands, as the node says; none where it says nothing, or throws.
  P2pPathKind _pathTo(String nodeId) {
    try {
      return p2p.node.pathTo(nodeId)?.kind ?? P2pPathKind.none;
    } catch (_) {
      return P2pPathKind.none;
    }
  }

  /// Whether a stream to [account]'s device at [nodeId] is open and proved.
  bool linkedTo(String account, String nodeId) => _nodes[nodeId]?.proved(account) != null;

  /// The proved stream open to [account]'s device at [nodeId], as a link to say something on ([Switchboard.sendOn]);
  /// null where none is open.
  Object? lineTo(String account, String nodeId) => _nodes[nodeId]?.proved(account);

  /// The node at the other end of [line] (one [Arrived.line] came on), while it is open and proved; null otherwise.
  String? nodeOf(Object? line) => line is _Line && !line.closed && line.account != null ? line.stream.nodeId : null;

  @override
  bool linked(Peer peer) => _wanted && p2p.devicesOf(peer.id).any((d) => linkedTo(peer.id, d.nodeId));

  @override
  bool get linkedToSomeone => _wanted && _nodes.values.any((n) => n.lines.any((l) => !l.closed && l.account != null && l.account != p2p.me));

  /// A stream this device dialled ([dialled]: whose device it dialled), or one another node opened.
  void _adopt(P2pStream s, {String? dialled}) {
    if (s.channel != P2pChannel.packets) {
      // Another channel's (a relay hosted here): whoever that is for takes it.
      if (dialled != null) _drop(s);
      return;
    }
    // Whose device the node at the other end is said to be: a stream from a node no card is held for is closed.
    final claimed = dialled != null ? (p2p.deviceAt(dialled, s.nodeId) != null && p2p.mayLink(dialled) ? [dialled] : const <String>[]) : p2p.accountsOf(s.nodeId);
    if (!_wanted || p2p.nodeId == null || claimed.isEmpty) return _drop(s);
    final node = _nodes[s.nodeId] ??= _Node();
    // No more than [opensAMinute] streams a minute from one node, whoever it is: each costs a handshake.
    if (dialled == null) {
      final now = p2p.nowMs;
      node.opens.removeWhere((t) => now - t >= 60000);
      if (node.opens.length >= opensAMinute) return _drop(s);
      node.opens.add(now);
    }
    // A stream that has not proved whose it is takes the place of another such, never of one that has (second review,
    // S3): a friend who names someone else's node as his can't close her links with this device by dialling it.
    for (var proving = node.lines.where((l) => l.account == null).toList(); proving.length >= mostProving; proving.removeAt(0)) {
      _close(node, proving.first);
    }
    final line = _Line(s, claimed, dialled: dialled, nonce: NetCrypto.randomBytes(_nonceLength));
    node.lines.add(line);
    // Not proved in the time a dial has, it is closed.
    line.timer = p2p.timer(p2p.policy.dialFor, () => _close(node, line));
    line.sub = s.frames.listen((f) => _frame(node, line, f), onDone: () => _gone(node, line), onError: (Object _) => _gone(node, line));
    // Each end's nonce first, whichever opened it.
    _send(node, line, Uint8List.fromList([_mark, _nonceMark, ...line.nonce]));
    p2p.linesChanged();
    node.bump();
  }

  /// Closes a stream that is not taken.
  static void _drop(P2pStream s) {
    try {
      unawaited(s.close().catchError((Object _) {}));
    } catch (_) {}
  }

  /// Puts a frame of the handshake on [line]; a stream that won't take it is closed.
  void _send(_Node node, _Line line, Uint8List frame) {
    try {
      line.stream.add(frame).catchError((Object _) => _close(node, line));
    } catch (_) {
      _close(node, line);
    }
  }

  /// What [fromAccount]'s device at [fromNode] says to [toAccount]'s at [toNode] to prove whose it is, on a stream whose
  /// nonces are [toNonce] (the other end's) and [fromNonce] (its own); null where no key is held with [account], the
  /// one of the two that is not this account (or this account's own, for its own devices).
  Uint8List? _proof(String account, {required String fromAccount, required String fromNode, required String toAccount, required String toNode, required List<int> toNonce, required List<int> fromNonce}) {
    final key = p2p.linkKey(account);
    if (key == null) return null;
    return Uint8List.fromList([
      _mark,
      _proofMark,
      ...NetCrypto.hmac(key, [..._words, ...NetCrypto.unhex(fromAccount), ...NetCrypto.unhex(fromNode), ...NetCrypto.unhex(toAccount), ...NetCrypto.unhex(toNode), ...toNonce, ...fromNonce]),
    ]);
  }

  /// Says, on [line], that this device is this account's and is talking to [account]'s.
  void _prove(_Node node, _Line line, String account) {
    final mine = p2p.nodeId, theirs = line.theirs;
    final proof = mine == null || theirs == null ? null : _proof(account, fromAccount: p2p.me, fromNode: mine, toAccount: account, toNode: line.stream.nodeId, toNonce: theirs, fromNonce: line.nonce);
    if (proof == null) return _close(node, line);
    _send(node, line, proof);
  }

  /// Whose device the other end of [line] has proved to be with [frame], of those its node is said to be; null where it
  /// is no proof of any.
  String? _whose(_Line line, Uint8List frame) {
    final mine = p2p.nodeId, theirs = line.theirs;
    if (mine == null || theirs == null) return null;
    for (final account in line.claimed) {
      final want = _proof(account, fromAccount: account, fromNode: line.stream.nodeId, toAccount: p2p.me, toNode: mine, toNonce: line.nonce, fromNonce: theirs);
      if (want != null && _same(want, frame)) return account;
    }
    return null;
  }

  /// Compared whole, however early they differ.
  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  /// A frame came on [line]: too long, the stream is closed; too many, it is dropped; before the stream has proved
  /// whose it is, only the proving is taken; after, only a packet from the account it proved to be is handed on.
  void _frame(_Node node, _Line line, Uint8List frame) {
    if (line.closed) return;
    // Longer than a packet may be: refused, and whoever sends such is not listened to further.
    if (frame.length > maxPacket) return _close(node, line);
    // Faster than a stream, or its account's devices together, may bring things: dropped, unread.
    final account = line.account;
    if (account != null) {
      final now = p2p.nowMs;
      if (!line.bucket.take(now) || !(_buckets[account] ??= _Bucket(accountBurst, accountPerSecond)).take(now)) {
        dropped++;
        return;
      }
    }
    if (line.account == null) {
      // The other end's nonce, then its proof; anything else, and the stream is closed.
      if (frame.length < 2 || frame[0] != _mark) return _close(node, line);
      if (line.theirs == null) {
        if (frame[1] != _nonceMark || frame.length != 2 + _nonceLength) return _close(node, line);
        line.theirs = Uint8List.fromList(frame.sublist(2));
        // The end that dialled proves first.
        final dialled = line.dialled;
        if (dialled != null) _prove(node, line, dialled);
        return;
      }
      if (frame[1] != _proofMark || frame.length != 2 + 32) return _close(node, line);
      final who = _whose(line, frame);
      if (who == null || !p2p.mayLink(who)) return _close(node, line);
      line.account = who;
      if (line.stream.incoming) _prove(node, line, who);
      p2p.heardFrom(who, line.stream.nodeId);
      _said(node, line);
      // Proved: it takes the place of the oldest proved one, where there are as many as are held.
      for (var proved = node.lines.where((l) => l.account != null && !identical(l, line)).toList(); proved.length >= mostLines; proved.removeAt(0)) {
        _close(node, proved.first);
      }
      p2p.linesChanged();
      node.bump();
      return;
    }
    // A packet's first byte is never 0 (packet.dart): anything else that is not one is passed over. And only a packet
    // from the account the stream proved to be (or, on one of this account's own, one it passed on) counts as
    // something said and is handed on: junk keeps nothing open (second review, M2).
    if (frame.isEmpty || frame[0] == _mark) return;
    final packet = Packet.parse(frame);
    if (packet == null || (packet.passed ? p2p.me : packet.from) != line.account) return;
    _said(node, line);
    _arrived.add(Arrived(id, frame, from: line.account, line: line));
  }

  /// Something was said on [line]: it is let go once nothing has been for [P2pPolicy.quiet].
  void _said(_Node node, _Line line) {
    line.timer?.cancel();
    line.timer = p2p.timer(p2p.policy.quiet, () => _close(node, line));
  }

  /// Lets [line] go, and closes its stream.
  void _close(_Node node, _Line line) {
    if (line.closed) return;
    _gone(node, line);
    _drop(line.stream);
  }

  /// [line] is over, whichever end ended it: no longer among [node]'s, and whoever waits on the node looks again.
  void _gone(_Node node, _Line line) {
    if (line.closed) return;
    line.closed = true;
    line.timer?.cancel();
    line.sub?.cancel();
    node.lines.remove(line);
    // Dialled for an account, and never proved to be its: as good as not reached, for that account alone. The same
    // node dialled for another account is another matter (second review, S3).
    final dialled = line.dialled;
    if (line.account == null && dialled != null) node.dialFor(dialled).failed = p2p.nowMs;
    p2p.linesChanged();
    node.bump();
  }

  /// Every stream is closed: Direct was switched off, or the app is closing.
  void closeAll() {
    for (final node in _nodes.values.toList()) {
      for (final line in node.lines.toList()) {
        _close(node, line);
      }
    }
  }

  /// Nothing is kept of what accounts this device no longer links with may bring.
  void forgetAccounts(bool Function(String account) keep) => _buckets.removeWhere((account, _) => !keep(account));

  /// No card is held for [nodeId] any more: nothing of it is kept here. (The node itself closes its streams.)
  void forget(String nodeId) {
    final node = _nodes[nodeId];
    if (node == null) return;
    for (final line in node.lines.toList()) {
      _close(node, line);
    }
    if (node.dials.values.every((d) => d.dials == 0)) _nodes.remove(nodeId);
    node.bump();
  }

  /// The device at [nodeId] said anew where it is, or its card came: whoever waits for it looks again.
  void heard(String nodeId) => _nodes[nodeId]?.bump();

  /// Whoever waits for anything looks again.
  void poke() {
    for (final node in _nodes.values.toList()) {
      node.bump();
    }
  }

  /// The network changed: devices that could not be reached may be now.
  void networkChanged() {
    for (final node in _nodes.values.toList()) {
      for (final dial in node.dials.values) {
        dial.failed = 0;
        dial.dialledAt = -1;
      }
      node.bump();
    }
  }

  // --- dialling ----------------------------------------------------------------------------------------------------------

  /// Dials [account]'s device at [nodeId] where no stream to it is open, with the time a dial has: when a friend's
  /// device asked to meet, and when the relay has gone.
  void reach(String nodeId, String account) {
    p2p.busy(true);
    unawaited(_reach(nodeId, account, p2p.nowMs + p2p.policy.dialFor.inMilliseconds).then((_) {}, onError: (Object _) {}).whenComplete(() => p2p.busy(false)));
  }

  /// A proved stream to [account]'s device at [nodeId], dialled where none is open; null where none could be had by
  /// [until]. A stream the device opens meanwhile serves as well as one dialled.
  Future<_Line?> _reach(String nodeId, String account, int until) async {
    while (true) {
      if (!_wanted) return null;
      final node = _nodes[nodeId] ??= _Node();
      final line = node.proved(account);
      if (line != null) return line;
      final device = p2p.deviceAt(account, nodeId);
      final now = p2p.nowMs;
      if (device == null || !p2p.mayLink(account) || now >= until || p2p.nodeState != P2pState.up) return null;
      // Dialled where nothing is on its way already: by where it last said it was, again when it says anew, and
      // not again within a while of failing. All of it for this account at this node: what became of a dial for
      // another account to the same node says nothing of this one (second review, S3).
      final dial = node.dialFor(account);
      final said = device.where?.at ?? 0;
      final anew = said > dial.dialledAt;
      if (!node.proving(account) && (dial.dials == 0 || anew) && (anew || now - dial.failed >= p2p.policy.redialAfter.inMilliseconds)) {
        dial.dials++;
        dial.dialledAt = said;
        Future<P2pStream> opening;
        try {
          opening = p2p.node.open(nodeId, P2pChannel.packets, hint: p2p.hintFor(device), timeout: Duration(milliseconds: until - now));
        } catch (e) {
          opening = Future.error(e);
        }
        unawaited(opening.then((s) {
          dial.dials--;
          dial.failed = 0;
          _adopt(s, dialled: account);
          node.bump();
        }, onError: (Object _) {
          dial.dials--;
          dial.failed = p2p.nowMs;
          node.bump();
        }));
      }
      // Nothing on its way, and no answer to a meet to wait for: there is no more to hope for now.
      if (dial.dials == 0 && !node.proving(account) && !p2p.awaited(account)) return null;
      await _changed(node, until);
    }
  }

  /// Waits until something about [node] changes, or [until].
  Future<void> _changed(_Node node, int until) {
    final left = until - p2p.nowMs;
    if (left <= 0) return Future.value();
    final done = Completer<void>();
    final wait = p2p.timer(Duration(milliseconds: left), () {
      if (!done.isCompleted) done.complete();
    });
    (node.changed ??= Completer<void>()).future.then((_) {
      wait.cancel();
      if (!done.isCompleted) done.complete();
    });
    return done.future;
  }

  /// Puts [packet] on [line], waiting until [until], and never less than [putAtLeast], for the stream to take it. A
  /// stream that fails it is closed; one that is only slow is left open, the core may yet take it (second review, S11).
  Future<_Put> _put(_Node node, _Line line, Uint8List packet, int until) async {
    final done = Completer<_Put>();
    final left = until - p2p.nowMs, least = putAtLeast.inMilliseconds;
    final wait = p2p.timer(Duration(milliseconds: left < least ? least : left), () {
      if (!done.isCompleted) done.complete(_Put.slow);
    });
    try {
      line.stream.add(packet).then((_) {
        if (!done.isCompleted) done.complete(_Put.took);
      }, onError: (Object _) {
        if (!done.isCompleted) done.complete(_Put.failed);
      });
    } catch (_) {
      if (!done.isCompleted) done.complete(_Put.failed);
    }
    final put = await done.future;
    wait.cancel();
    switch (put) {
      case _Put.took:
        if (!line.closed) _said(node, line);
      case _Put.failed:
        _close(node, line);
      case _Put.slow:
        break;
    }
    return put;
  }

  /// Gets [packet] to [account]'s device at [nodeId] by [until], on a stream that is open or one that can be had.
  Future<bool> _give(String nodeId, String account, Uint8List packet, int until) async {
    try {
      while (true) {
        final line = await _reach(nodeId, account, until);
        final node = _nodes[nodeId];
        if (line == null || node == null) return false;
        final put = await _put(node, line, packet, until);
        if (put == _Put.took) return true;
        // Slow: not put on that stream again, nor another dialled, while it may yet go.
        if (put == _Put.slow || p2p.nowMs >= until) return false;
      }
    } catch (_) {
      return false;
    }
  }

  @override
  Future<Handed> send(Peer peer, Uint8List packet) async {
    if (!_wanted || !p2p.loaded) throw CarrierError('Direct is switched off');
    if (packet.length > maxPacket) throw CarrierError('too long for a direct link');
    final account = peer.id;
    if (!p2p.mayLink(account)) throw CarrierError('this device does not link with them now');
    // Not a device of theirs unheard from in [P2p.staleAfter] while another has been: an install from before.
    final known = p2p.devicesOf(account);
    final latest = known.fold(0, (int n, d) => d.heard > n ? d.heard : n);
    final devices = [for (final d in known) if (latest - d.heard < P2p.staleAfter.inMilliseconds || linkedTo(account, d.nodeId)) d];
    if (devices.isEmpty) throw CarrierError('no device of theirs is known');
    final until = p2p.nowMs + p2p.policy.dialFor.inMilliseconds;
    p2p.busy(true);
    final took = Completer<bool>();
    try {
      // A phone's node is started for this: a send of its own is a reason for it to be up a while.
      p2p.reason();
      await p2p.up();
      // No stream open to any of their devices: asked to meet as well, where something else carries the asking.
      if (!devices.any((d) => linkedTo(account, d.nodeId))) unawaited(p2p.meet(account, until).then((_) {}, onError: (Object _) {}));
      var left = devices.length;
      for (final d in devices) {
        p2p.busy(true);
        unawaited(_give(d.nodeId, account, packet, until).then((ok) {
          p2p.busy(false);
          if (ok && !took.isCompleted) took.complete(true);
          if (--left == 0 && !took.isCompleted) took.complete(false);
        }));
      }
      // Passed as soon as one device took it; the others are still tried until the time is up.
      if (!await took.future) throw CarrierError('none of their devices could be reached directly');
      return Handed.passed;
    } finally {
      p2p.busy(false);
    }
  }

  @override
  Future<Handed> sendLinked(Peer peer, Uint8List packet) async {
    final until = _sendable(packet);
    if (!await _byLinks(peer, packet, until)) throw CarrierError('no link to them is open now');
    // A send of this device's own: a reason for a phone's node to stay up a while.
    p2p.reason();
    return Handed.passed;
  }

  /// An answer goes back on the stream what it answers came by, else by another open to them; never by a dial, and it
  /// is no reason for a phone's node to stay up: it was the other device that spoke (second review, S7).
  @override
  Future<Handed> sendOn(Peer peer, Object? line, Uint8List packet) async {
    final until = _sendable(packet);
    if (line is _Line && !line.closed && line.account == peer.id) {
      final node = _nodes[line.stream.nodeId];
      if (node != null && await _put(node, line, packet, until) == _Put.took) return Handed.passed;
    }
    if (!await _byLinks(peer, packet, until)) throw CarrierError('no link to them is open now');
    return Handed.passed;
  }

  /// When a send of [packet] by the links open now must be done by; throws where it can't be sent this way at all.
  int _sendable(Uint8List packet) {
    if (!_wanted || !p2p.loaded) throw CarrierError('Direct is switched off');
    if (packet.length > maxPacket) throw CarrierError('too long for a direct link');
    return p2p.nowMs + p2p.policy.dialFor.inMilliseconds;
  }

  /// Puts [packet] on the open streams with [peer]'s devices, one each; whether any took it.
  Future<bool> _byLinks(Peer peer, Uint8List packet, int until) async {
    var took = false;
    for (final d in p2p.mayLink(peer.id) ? p2p.devicesOf(peer.id) : const <P2pDevice>[]) {
      final node = _nodes[d.nodeId], line = node?.proved(peer.id);
      if (node == null || line == null) continue;
      if (await _put(node, line, packet, until) == _Put.took) took = true;
    }
    return took;
  }

  Future<void> dispose() async {
    await _opened?.cancel();
    _opened = null;
    await _arrived.close();
  }
}

/// So many things at once, and so many more each second after: what someone may bring in a while.
class _Bucket {
  _Bucket(this.most, this.perSecond) : _left = most.toDouble();
  final int most, perSecond;
  double _left;
  int _at = 0;

  /// Whether one more may come at [now], counted where it may.
  bool take(int now) {
    if (_at > 0 && now > _at) _left = (_left + (now - _at) * perSecond / 1000).clamp(0, most).toDouble();
    _at = now;
    if (_left < 1) return false;
    _left -= 1;
    return true;
  }
}

/// What became of a frame put on a stream: taken; failed (the stream is gone); or slow, not taken in its time.
enum _Put { took, failed, slow }

/// One stream with a device, and whose the device has proved to be.
class _Line {
  _Line(this.stream, this.claimed, {this.dialled, required this.nonce});
  final P2pStream stream;

  /// The accounts whose cards name the node at the other end (for a stream this device dialled, the one it dialled).
  final List<String> claimed;

  /// The account whose device this one dialled; null for a stream the other end opened.
  final String? dialled;

  /// This end's nonce, and the other end's once it has come.
  final Uint8List nonce;
  Uint8List? theirs;

  /// Which of them it proved to be; null until its proof has come.
  String? account;

  /// What it may still bring now ([P2pCarrier.lineBurst]).
  final bucket = _Bucket(P2pCarrier.lineBurst, P2pCarrier.linePerSecond);

  /// The listening to its frames, the wait that lets it go when nothing is said on it, and whether it is over.
  StreamSubscription<Uint8List>? sub;
  Timer? timer;
  bool closed = false;
}

/// What is under way with one node: its streams, the dials on their way to it for each account it is said to be a
/// device of, and whoever waits for either.
class _Node {
  final List<_Line> lines = [];

  /// When each stream it opened in the last minute was taken.
  final List<int> opens = [];

  /// The dials to it, for each account whose device it was dialled as.
  final Map<String, _Dial> dials = {};
  Completer<void>? changed;

  /// The dials to it as [account]'s device, begun where there are none.
  _Dial dialFor(String account) => dials[account] ??= _Dial();

  /// An open stream that has proved to be [account]'s; null where there is none.
  _Line? proved(String account) => lines.where((l) => l.account == account && !l.closed).firstOrNull;

  /// Whether a stream that may yet prove to be [account]'s is open: one dialled for it, or one the other end opened
  /// that [account]'s card names.
  bool proving(String account) => lines.any((l) => l.account == null && !l.closed && (l.dialled == null ? l.claimed.contains(account) : l.dialled == account));

  /// Something changed: whoever waits looks again.
  void bump() {
    final c = changed;
    changed = null;
    c?.complete();
  }
}

/// The dials to one node for one account: how many are on their way, the time on the whereabouts the last went by
/// (-1 before any), and when it last could not be reached (0 where it since could, or the network changed).
class _Dial {
  int dials = 0;
  int dialledAt = -1;
  int failed = 0;
}
