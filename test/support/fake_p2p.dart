import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:ghost_messaging/net/crypto.dart';
import 'package:ghost_messaging/net/p2p/node.dart';

/// The direct network with nothing under it (lib/net/p2p/node.dart): nodes in one process that find each other
/// through a [FakeP2pMesh] in memory, held to every sentence of [P2pNode]'s contract (test/fake_p2p_test.dart). The
/// direct route is built and tested against it; the real node (Rust on iroh, native/p2p) stands behind the same
/// interface.
///
///   final mesh = FakeP2pMesh();                         // with a clock of its own, or FakeP2pMesh(clock: clock)
///   final a = mesh.node(), b = mesh.node();
///   await a.start(P2pConfig(secret: keyA));             // up, with an address on the mesh's one network
///   b.allow(a.nodeId!, {P2pChannel.packets});           // …after b has started too
///   final s = await a.open(b.nodeId!, P2pChannel.packets, hint: b.whereabouts.value);
///   mesh.unreachable(b);                                // nothing reaches it: a dial waits out its time and fails
///   mesh.natted(b);                                     // reached only through a link helper
///   mesh.inbound(b, false);                             // it dials out, and nothing dials in
///   mesh.slow(b, const Duration(seconds: 2));           // a dial to it takes that long
///   await mesh.clock.pass(const Duration(seconds: 5));  // time moves when a test says so, never by itself
///   b.throws.add('disallow');                           // a core that breaks node.dart's word: it throws there
///   b.hangsOn.add('add');                               // …or never answers
///   Net.p2pNode = FakeP2pMesh.broken(StateError('…'));   // a core whose library would not load
///
/// What it knows of the real thing, so a test fails where the app would: a node gets a new address each time it
/// starts (a dial by an old one finds nothing), a dial keeps trying until its time is up (a node that comes up
/// meanwhile is found), nothing is found without being told where it is (no directory), and a link helper is used
/// only where the one dialling was given it too.

/// A clock a test moves by hand: what time it is, and timers that fire as it is moved on. Nothing here waits on the
/// machine: under any load the same things happen in the same order.
class FakeClock {
  // From now: an envelope carries the real time it was made.
  FakeClock([DateTime? start]) : _t = start ?? DateTime.now();
  DateTime _t;
  int _made = 0;
  final List<_FakeTimer> _timers = [];

  DateTime now() => _t;
  int get ms => _t.millisecondsSinceEpoch;

  /// A timer that fires when the clock is moved to its time: what the direct network is given in place of `Timer.new`.
  Timer timer(Duration after, void Function() then) {
    final t = _FakeTimer(this, _t.add(after.isNegative ? Duration.zero : after), _made++, then);
    _timers.add(t);
    return t;
  }

  /// How many timers are waiting to fire.
  int get waiting => _timers.length;

  /// When the next timer falls due; null with none waiting.
  DateTime? get next => _first()?.due;

  _FakeTimer? _first({DateTime? by}) {
    _FakeTimer? first;
    for (final t in _timers) {
      if (by != null && t.due.isAfter(by)) continue;
      if (first == null || t.due.isBefore(first.due) || (t.due == first.due && t.order < first.order)) first = t;
    }
    return first;
  }

  /// Lets everything that is ready to run, run, with no time passing: what was said in memory is heard, and what
  /// that sets off is done.
  Future<void> settle([int turns = 30]) async {
    for (var i = 0; i < turns; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Moves the clock on by [d]. Each timer that falls due on the way fires at its own moment, in order, and what it
  /// sets off runs before the next.
  Future<void> pass(Duration d) async {
    final end = _t.add(d);
    await settle();
    for (var t = _first(by: end); t != null; t = _first(by: end)) {
      if (t.due.isAfter(_t)) _t = t.due;
      _timers.remove(t);
      t.fire();
      await settle();
    }
    _t = end;
    await settle();
  }
}

class _FakeTimer implements Timer {
  _FakeTimer(this._clock, this.due, this.order, this._then);
  final FakeClock _clock;
  final DateTime due;
  final int order;
  final void Function() _then;
  bool _active = true;

  void fire() {
    if (!_active) return;
    _active = false;
    _then();
  }

  @override
  void cancel() {
    _active = false;
    _clock._timers.remove(this);
  }

  @override
  bool get isActive => _active;
  @override
  int get tick => 0;
}

/// Where the stand-in nodes find each other, and what a test does to the paths between them.
class FakeP2pMesh {
  FakeP2pMesh({FakeClock? clock}) : clock = clock ?? FakeClock();

  /// What dials wait by: a dial's time runs out when the test moves this on, never by itself.
  final FakeClock clock;

  final List<FakeP2pNode> nodes = [];

  /// Every dial made, in order: who dialled whom, on which channel, and by what it was told of where they are.
  final List<({FakeP2pNode from, String to, int channel, Whereabouts? hint})> dials = [];

  /// How many frames have crossed.
  int frames = 0;

  final Set<FakeP2pNode> _unreachable = {}, _natted = {}, _deaf = {};
  final Map<FakeP2pNode, Duration> _slow = {};
  final Set<String> _cut = {};
  final Set<String> _helpersDown = {};
  final List<_Dial> _pending = [];
  final Map<String, _Link> _links = {};
  int _ports = 40000;

  /// What makes the app's node (Net.p2pNode) in a build whose core can't be loaded: it throws [error], as loading a
  /// library that is missing, or built for another machine, does.
  static P2pNode Function() broken(Object error) => () => throw error;

  /// A node, not started. Nodes on one [network] reach each other's addresses as they are; nodes on different ones
  /// only through a link helper.
  FakeP2pNode node({String network = 'home'}) {
    final n = FakeP2pNode._(this, network);
    nodes.add(n);
    return n;
  }

  /// How many dials were made to [nodeId].
  int dialsTo(String nodeId) => dials.where((d) => d.to == nodeId).length;

  /// Nothing reaches [n] and it reaches nothing (no network at all): a dial waits out its time and fails.
  void unreachable(FakeP2pNode n, [bool yes = true]) => _set(_unreachable, n, yes);

  /// No straight path to or from [n] (a router that lets nothing in): it is reached only through a link helper.
  void natted(FakeP2pNode n, [bool yes = true]) => _set(_natted, n, yes);

  /// Whether anything can dial [n] (a router that lets out what it will not let in): with [yes] false it still dials
  /// others, and a link it made itself carries both ways.
  void inbound(FakeP2pNode n, bool yes) => _set(_deaf, n, !yes);

  /// A dial to or from [n] takes [dial] by the mesh's clock ([Duration.zero]: at once again).
  void slow(FakeP2pNode n, Duration dial) {
    if (dial == Duration.zero) {
      _slow.remove(n);
    } else {
      _slow[n] = dial;
    }
    _changed();
  }

  /// [a] and [b] can't reach each other at all, though each reaches everyone else.
  void cut(FakeP2pNode a, FakeP2pNode b, [bool yes = true]) {
    final key = _pair(a, b);
    if (yes) {
      _cut.add(key);
      for (final s in a._streams.where((s) => identical(s._other!._owner, b)).toList()) {
        _close(s);
      }
    } else {
      _cut.remove(key);
    }
    _changed();
  }

  /// The link helper at [url] is not answering.
  void helperDown(String url, [bool yes = true]) {
    if (yes) {
      _helpersDown.add(url);
    } else {
      _helpersDown.remove(url);
    }
    _changed();
  }

  void _set(Set<FakeP2pNode> set, FakeP2pNode n, bool yes) {
    if (yes) {
      set.add(n);
      // A path that was there is gone with the network.
      if (identical(set, _unreachable)) {
        for (final s in n._streams.toList()) {
          _close(s);
        }
      }
    } else {
      set.remove(n);
    }
    _changed();
  }

  static String _pair(FakeP2pNode a, FakeP2pNode b) => a._serial < b._serial ? '${a._serial}:${b._serial}' : '${b._serial}:${a._serial}';

  String _address(FakeP2pNode n) => '10.${n.network.hashCode % 200}.0.${n._serial + 2}:${_ports++}';

  /// How [from] would reach [to] now, knowing of it what [hint] says and what it already knew; null where it can't.
  P2pPathKind? _path(FakeP2pNode from, FakeP2pNode to, Whereabouts? hint) {
    if (_unreachable.contains(from) || _unreachable.contains(to) || _cut.contains(_pair(from, to))) return null;
    final up = _links[_pair(from, to)];
    if (up != null) return up.kind;
    final there = to._where.value;
    if (there == null || _deaf.contains(to)) return null;
    final told = [?hint, ?from._known[to._id]];
    // Straight: it was told an address the other has now, both let a straight path be, and they share a network.
    final address = told.any((w) => w.addresses.any(there.addresses.contains));
    if (address && !from._config!.helpersOnly && !to._config!.helpersOnly && !_natted.contains(from) && !_natted.contains(to) && from.network == to.network) return P2pPathKind.direct;
    // Through a link helper: the one the other is on now, which the one dialling was given too and was told of.
    final helper = there.helper;
    if (helper != null && !_helpersDown.contains(helper) && from._config!.helpers.contains(helper) && told.any((w) => w.helper == helper)) return P2pPathKind.helper;
    return null;
  }

  /// Something about who can reach whom changed: every dial still trying looks again.
  void _changed() {
    for (final d in _pending.toList()) {
      _try(d);
    }
  }

  void _try(_Dial d) {
    if (d.done.isCompleted) return;
    final from = d.from;
    if (from._state.value != P2pState.up || from._run != d.run) return d.fail('this node is not up');
    final to = nodes.where((n) => n._id == d.to && n._state.value == P2pState.up).firstOrNull;
    if (to == null) return;
    final kind = _path(from, to, d.hint);
    if (kind == null) return;
    // Found: the link takes its time to make where the test said so.
    final takes = [_slow[from], _slow[to]].whereType<Duration>().fold(Duration.zero, (a, b) => b > a ? b : a);
    if (takes > Duration.zero && !d.waited) {
      d.linking ??= clock.timer(takes, () {
        d.waited = true;
        _try(d);
      });
      return;
    }
    // The handshake said who is dialling: turned away unless let in.
    if (!to._lets(from._id!, d.channel)) return d.fail('it turned this device away');
    final ours = _FakeStream(from, to._id!, d.channel, false), theirs = _FakeStream(to, from._id!, d.channel, true);
    ours._other = theirs;
    theirs._other = ours;
    from._streams.add(ours);
    to._streams.add(theirs);
    final key = _pair(from, to);
    final link = _links[key];
    if (link == null) {
      _links[key] = _Link(kind)..streams = 1;
      from._known[to._id!] = to._where.value!;
      if (from._where.value != null) to._known[from._id!] = from._where.value!;
      from._paths.add(P2pPath(to._id!, kind, rttMs: _rtt(kind)));
      to._paths.add(P2pPath(from._id!, kind, rttMs: _rtt(kind)));
    } else {
      link.streams++;
    }
    d.succeed(ours);
    to._opened.add(theirs);
  }

  static int _rtt(P2pPathKind kind) => kind == P2pPathKind.direct ? 4 : 60;

  void _close(_FakeStream s) {
    if (s._closed) return;
    final other = s._other!;
    s._closed = other._closed = true;
    s._owner._streams.remove(s);
    other._owner._streams.remove(other);
    // What was already sent is heard first, then each end's frames are done.
    s._in.close();
    other._in.close();
    final key = _pair(s._owner, other._owner);
    final link = _links[key];
    if (link != null && --link.streams <= 0) {
      _links.remove(key);
      s._owner._paths.add(P2pPath(s.nodeId, P2pPathKind.none));
      other._owner._paths.add(P2pPath(other.nodeId, P2pPathKind.none));
    }
  }
}

class _Link {
  _Link(this.kind);
  final P2pPathKind kind;
  int streams = 0;
}

class _Dial {
  _Dial(this.from, this.run, this.to, this.channel, this.hint);
  final FakeP2pNode from;
  final int run;
  final String to;
  final int channel;
  final Whereabouts? hint;
  final done = Completer<P2pStream>();
  Timer? deadline, linking;

  /// The time a slow link takes has passed.
  bool waited = false;

  void succeed(P2pStream s) => _end(() => done.complete(s));
  void fail(String why) => _end(() => done.completeError(P2pError(why)));

  void _end(void Function() how) {
    if (done.isCompleted) return;
    deadline?.cancel();
    linking?.cancel();
    from.mesh._pending.remove(this);
    how();
  }
}

/// A node on a [FakeP2pMesh]: [P2pNode] as node.dart describes it, counted so a test can ask what was done to it. It
/// can also be made to break every promise node.dart makes ([throws], [hangsOn], [hangs], [failStarts]), as a real core
/// might: a test then sees what the direct route makes of a core that misbehaves.
class FakeP2pNode implements P2pNode {
  FakeP2pNode._(this.mesh, this.network) : _serial = mesh.nodes.length;
  final FakeP2pMesh mesh;
  final int _serial;

  /// The network it is on. Nodes on one network reach each other's addresses as they are.
  String network;

  /// How many times it was started and stopped, and each config it was started with.
  int starts = 0, stops = 0;
  final List<P2pConfig> configs = [];

  /// How many times it was told the network changed.
  int networkChanges = 0;

  /// How many times each call was made of it, by name ('allow', 'disallow', 'openToAll', 'networkChanged', 'pathTo').
  final Map<String, int> calls = {};

  /// Set, every start fails with these words until it is null again.
  String? failStarts;

  /// How long a start takes, by the mesh's clock.
  Duration startTakes = Duration.zero;

  /// How long each frame put on one of its streams takes to go, by the mesh's clock (a real core across FFI is never
  /// instant): the frame reaches the other end, and the put answers, then.
  Duration addTakes = Duration.zero;

  /// Set, the node never answers a stop or what a key makes (a core that hangs): the stop is done all the same.
  bool hangs = false;

  /// The calls and getters that throw at once, as node.dart says none ever does: 'allow', 'disallow', 'openToAll',
  /// 'networkChanged', 'pathTo', 'nodeId', 'state', 'problem', 'whereabouts', 'opened', 'paths'; and 'idOf', 'start',
  /// 'stop', 'open', which node.dart says fail only through their Futures; and on its streams 'add' and 'close'.
  final Set<String> throws = {};

  /// The calls whose Futures never complete, as a core that hangs: 'start', 'open', and on its streams 'add' and
  /// 'close'. (A start that hangs leaves the node starting; an add that hangs takes the frame nowhere.)
  final Set<String> hangsOn = {};

  void _call(String name) {
    calls[name] = (calls[name] ?? 0) + 1;
    if (throws.contains(name)) throw P2pError('the core broke in $name');
  }

  P2pConfig? _config;
  String? _id;
  int _run = 0;
  Future<void>? _starting;
  final Map<String, Set<int>> _allowed = {};
  Set<int> _openToAll = const {};
  final List<_FakeStream> _streams = [];
  final Map<String, Whereabouts> _known = {};
  final _opened = StreamController<P2pStream>.broadcast();
  final _paths = StreamController<P2pPath>.broadcast();
  final ValueNotifier<P2pState> _state = ValueNotifier(P2pState.off);
  final ValueNotifier<Whereabouts?> _where = ValueNotifier(null);
  String? _problem;

  /// The node id a node key makes here: the same key, the same id, and nothing of the key in it.
  static String idFor(List<int> secret) => NetCrypto.hex(NetCrypto.sha256([...utf8.encode('fake p2p node '), ...secret]));

  /// Who is let in on which channels, for a test to look at.
  Map<String, Set<int>> get allowed => {for (final e in _allowed.entries) e.key: Set.of(e.value)};

  /// The config it is running with, or was last started with.
  P2pConfig? get config => _config;

  /// How many streams are open at this end.
  int get streams => _streams.length;

  /// How it stands, read by a test whatever [throws] says.
  P2pState get now => _state.value;

  @override
  String? get nodeId {
    _call('nodeId');
    return _id;
  }

  @override
  Future<String> idOf(Uint8List secret) {
    _call('idOf');
    return hangs ? Completer<String>().future : Future.value(idFor(secret));
  }

  @override
  ValueNotifier<P2pState> get state {
    _call('state');
    return _state;
  }

  @override
  String? get problem {
    _call('problem');
    return _problem;
  }

  set problem(String? why) => _problem = why;

  @override
  ValueNotifier<Whereabouts?> get whereabouts {
    _call('whereabouts');
    return _where;
  }

  bool get _running => _state.value == P2pState.up || _state.value == P2pState.starting;

  @override
  Future<void> start(P2pConfig config) async {
    _call('start');
    if (hangsOn.contains('start')) {
      _config = config;
      _state.value = P2pState.starting;
      return Completer<void>().future;
    }
    if (_running && _config == config) return _starting ?? Future<void>.value();
    if (_running) await stop();
    starts++;
    configs.add(config);
    _config = config;
    _problem = null;
    final run = ++_run;
    _state.value = P2pState.starting;
    return _starting = () async {
      if (startTakes > Duration.zero) {
        final waited = Completer<void>();
        mesh.clock.timer(startTakes, waited.complete);
        await waited.future;
      } else {
        await Future<void>.value();
      }
      // Stopped, or started again, while this start was under way.
      if (run != _run) return;
      _starting = null;
      final why = failStarts;
      if (why != null) {
        _problem = why;
        _state.value = P2pState.down;
        return;
      }
      _id = idFor(config.secret);
      _state.value = P2pState.up;
      _whereNow();
      mesh._changed();
    }();
  }

  /// A new address, as a node binds one each time it starts and each time its network changes.
  void _whereNow() {
    final c = _config!;
    _where.value = Whereabouts(helper: c.helpers.firstOrNull, addresses: c.helpersOnly ? const [] : List.unmodifiable([mesh._address(this)]), at: mesh.clock.ms);
  }

  /// The device moved to [network] (Wi-Fi to mobile data): its old address finds nothing, and its links are gone.
  void move(String network) {
    this.network = network;
    if (_state.value != P2pState.up) return;
    for (final s in _streams.toList()) {
      mesh._close(s);
    }
    _whereNow();
    mesh._changed();
  }

  /// It stops by itself, as a core that failed does: [problem] says why.
  void fail(String why) {
    _end();
    _problem = why;
    _state.value = P2pState.down;
  }

  @override
  Future<void> stop() {
    _call('stop');
    if (_state.value != P2pState.off) {
      stops++;
      _end();
      _problem = null;
      _state.value = P2pState.off;
    }
    return hangs ? Completer<void>().future : Future.value();
  }

  void _end() {
    _run++;
    _starting = null;
    for (final s in _streams.toList()) {
      mesh._close(s);
    }
    for (final d in mesh._pending.where((d) => identical(d.from, this)).toList()) {
      d.fail('this node is not up');
    }
    _known.clear();
    _where.value = null;
  }

  @override
  void networkChanged() {
    _call('networkChanged');
    networkChanges++;
  }

  @override
  void allow(String nodeId, Set<int> channels) {
    _call('allow');
    _allowed[nodeId] = Set.of(channels);
  }

  @override
  void disallow(String nodeId) {
    _call('disallow');
    _allowed.remove(nodeId);
    for (final s in _streams.where((s) => s.nodeId == nodeId).toList()) {
      mesh._close(s);
    }
  }

  @override
  void openToAll(Set<int> channels) {
    _call('openToAll');
    _openToAll = Set.of(channels);
  }

  bool _lets(String nodeId, int channel) => _openToAll.contains(channel) || (_allowed[nodeId]?.contains(channel) ?? false);

  @override
  Future<P2pStream> open(String nodeId, int channel, {Whereabouts? hint, Duration timeout = const Duration(seconds: 5)}) {
    _call('open');
    mesh.dials.add((from: this, to: nodeId, channel: channel, hint: hint));
    if (hangsOn.contains('open')) return Completer<P2pStream>().future;
    if (_state.value != P2pState.up) return Future.error(P2pError('this node is not up'));
    if (nodeId == _id) return Future.error(P2pError('a node does not dial itself'));
    final d = _Dial(this, _run, nodeId, channel, hint);
    mesh._pending.add(d);
    d.deadline = mesh.clock.timer(timeout, () => d.fail('it could not be reached'));
    mesh._try(d);
    return d.done.future;
  }

  @override
  Stream<P2pStream> get opened {
    _call('opened');
    return _opened.stream;
  }

  @override
  Stream<P2pPath> get paths {
    _call('paths');
    return _paths.stream;
  }

  @override
  P2pPath? pathTo(String nodeId) {
    _call('pathTo');
    // More than one node may have had this id: an app that started again is a new node with the same key.
    for (final other in mesh.nodes.where((n) => n._id == nodeId)) {
      final link = mesh._links[FakeP2pMesh._pair(this, other)];
      if (link != null) return P2pPath(nodeId, link.kind, rttMs: FakeP2pMesh._rtt(link.kind));
    }
    return null;
  }
}

class _FakeStream implements P2pStream {
  _FakeStream(this._owner, this.nodeId, this.channel, this.incoming);
  final FakeP2pNode _owner;
  _FakeStream? _other;
  bool _closed = false;
  final _in = StreamController<Uint8List>();

  @override
  final String nodeId;
  @override
  final int channel;
  @override
  final bool incoming;

  @override
  Stream<Uint8List> get frames => _in.stream;

  @override
  Future<void> add(Uint8List frame) {
    _owner._call('add');
    if (_owner.hangsOn.contains('add')) return Completer<void>().future;
    return _add(frame);
  }

  Future<void> _add(Uint8List frame) async {
    final takes = _owner.addTakes;
    if (takes > Duration.zero) {
      final went = Completer<void>();
      _owner.mesh.clock.timer(takes, went.complete);
      await went.future;
    }
    if (_closed) throw P2pError('the stream has closed');
    if (frame.length > P2pNode.maxFrame) throw P2pError('a frame is at most ${P2pNode.maxFrame} bytes');
    _owner.mesh.frames++;
    // The other end's own copy, whole, after those sent before it.
    _other!._in.add(Uint8List.fromList(frame));
  }

  @override
  Future<void> close() {
    _owner._call('close');
    if (_owner.hangsOn.contains('close')) return Completer<void>().future;
    return Future.sync(() => _owner.mesh._close(this));
  }
}
