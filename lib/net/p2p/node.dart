import 'dart:async';

import 'package:flutter/foundation.dart';

/// The direct network as the app holds it (docs/OPEN_NETWORK.md, section 2; Matt, 2026-11-22: "p2p as a secondary
/// back up that validates everything our relay says ... look at iroh as the rust backend for the p2p side").
///
/// A device is a **node**: a key made on the device, whose public half is its **node id** (64 hex digits). A node
/// offers one thing, framed streams to another node by its id, on a numbered **channel**. How a stream gets there
/// (dialling, getting through a NAT, falling back to a link helper) is the core's business (native/p2p, Rust on
/// iroh, reached by node_ffi.dart); nothing above this file knows. A test puts a stand-in in its place
/// (test/support/fake_p2p.dart), and a build without the core has no node at all.
///
/// Nothing here knows of accounts, friends or packets: the direct route (p2p_carrier.dart) says who may connect
/// ([P2pNode.allow]) and what the frames mean.
///
/// **What the core must guarantee** (the second review of the direct route, 2026-11-23). The Dart above is safe only
/// where every sentence below holds; each is said again at the member it is about. In short:
///
/// - Who is at the other end of a stream is proved by the core's own handshake ([P2pStream.nodeId]), and nothing of a
///   node that was not let in reaches the app ([P2pNode.allow], [P2pNode.opened]).
/// - What it is told takes effect before the call returns: [P2pNode.allow] replaces, [P2pNode.disallow] has closed
///   every stream with that node, both ways, by the time it returns, and who was let in outlives a stop and a start.
/// - It never throws where it is not let fail: the getters, [P2pNode.allow], [P2pNode.disallow], [P2pNode.openToAll],
///   [P2pNode.networkChanged] and [P2pNode.pathTo] never throw; [P2pNode.idOf], [P2pNode.start], [P2pNode.stop],
///   [P2pNode.open], [P2pStream.add] and [P2pStream.close] fail only through their Futures. [P2pNode.open] ends,
///   one way or the other, within its timeout. A stop asked for while a start is under way wins.
/// - Frames are whole and in order, at most [P2pNode.maxFrame] bytes; a longer one resets the stream. Flow control
///   bounds what is held in memory for a stream, and the core caps how many streams one node may hold open and how
///   many it may open in a while; handshakes it refuses are refused at a limited rate too.
/// - Everything between two nodes is encrypted end to end, with no 0-RTT data (nothing that could be replayed).
/// - Nothing is public: no DNS or pkarr record, no DHT, no mDNS, no relay (link helper) but those in
///   [P2pConfig.helpers]. With [P2pConfig.helpersOnly] it tells nobody an address of its own. It never dials a
///   loopback, unspecified, multicast, broadcast or link-local address a hint names. (Not yet kept by the core: QUIC's
///   hole punching inside iroh 1.5 sends a small probe to whatever address the other end of a link names, loopback
///   included, and iroh has no hook to stop it; native/p2p/README.md, "What a node that links can make this one
///   send".) Stopped, it holds no socket and sends nothing.
/// - What it says is true: [P2pNode.whereabouts] and [P2pNode.paths] say how things are, not how they were meant to be.
/// - Closing a stream delivers what was sent on it before, then ends the other end's [P2pStream.frames].
/// - Its events (state, whereabouts, paths, streams opened, frames) never come from within a call into it: never
///   re-entrant.
/// - A release build logs no node id, address or anything carried.

/// The channels a stream can be opened on.
abstract final class P2pChannel {
  /// Packets between two devices: the direct route.
  static const packets = 0;

  /// A hub connection to a relay hosted from an app (lib/relay_host).
  static const hub = 1;

  /// A relay talking to a relay (relay/lib/federation.dart).
  static const relays = 2;

  static const all = {packets, hub, relays};
}

/// Where a device can be found now: what it tells its account's devices and its friends', and what they dial with.
@immutable
class Whereabouts {
  const Whereabouts({this.helper, this.addresses = const [], this.at = 0});

  /// The link helper it can be reached through (`https://…`), where it has one.
  final String? helper;

  /// Its own addresses (`ip:port`), where it tells them; none where the person chose "Only through link helpers".
  final List<String> addresses;

  /// When it said so, in milliseconds.
  final int at;

  /// Whether it says nothing of where: no link helper and no address.
  bool get isEmpty => helper == null && addresses.isEmpty;

  Map<String, dynamic> toJson() => {'r': ?helper, if (addresses.isNotEmpty) 'a': addresses, 't': at};

  /// Null where [j] isn't one. No more than [mostAddresses] are kept, none longer than 64 characters: it comes from
  /// someone else's device.
  static Whereabouts? fromJson(Object? j) {
    if (j is! Map) return null;
    final r = j['r'], a = j['a'], t = j['t'];
    if (r != null && (r is! String || r.length > 200 || !r.startsWith('https://'))) return null;
    final list = <String>[];
    if (a is List) {
      for (final x in a) {
        if (x is String && x.length <= 64 && list.length < mostAddresses) list.add(x);
      }
    }
    return Whereabouts(helper: r as String?, addresses: List.unmodifiable(list), at: t is num ? t.toInt() : 0);
  }

  static const mostAddresses = 8;

  @override
  bool operator ==(Object other) => other is Whereabouts && other.helper == helper && listEquals(other.addresses, addresses);

  @override
  int get hashCode => Object.hash(helper, Object.hashAll(addresses));
}

/// How a node stands.
enum P2pState {
  /// Not started, or stopped.
  off,
  starting,

  /// Ready: it has a node id, and can dial and be dialled.
  up,

  /// It could not start, or stopped by itself; [P2pNode.problem] says why.
  down,
}

/// How the path to another node stands.
enum P2pPathKind {
  /// No link to it.
  none,

  /// Through a link helper: sealed end to end still, but slower, and the helper sees how much is said.
  helper,

  /// Straight between the two devices.
  direct,
}

/// The path to the node [nodeId] as it stands now.
@immutable
class P2pPath {
  const P2pPath(this.nodeId, this.kind, {this.rttMs});
  final String nodeId;
  final P2pPathKind kind;

  /// The round trip, in milliseconds, where the core has measured one.
  final int? rttMs;
}

/// What a node is started with.
@immutable
class P2pConfig {
  const P2pConfig({required this.secret, this.helpers = const [], this.helpersOnly = false});

  /// The node key: 32 bytes, made once on this device and kept in its secret store.
  final Uint8List secret;

  /// The link helpers' addresses (`https://…`), as the relay this app is on hands them out. With none, only devices
  /// that can reach each other's addresses as they are link up: on one network, or two nodes on one machine in a test.
  /// Nothing is ever looked up in, or told to, a public directory, and no relay or helper is used but these: not the
  /// core's own defaults, and not one another node names.
  final List<String> helpers;

  /// Never a straight path: the other device sees a link helper's address, not this one's. The core then tells nobody an
  /// address of its own, in a handshake or anywhere else.
  final bool helpersOnly;

  @override
  bool operator ==(Object other) => other is P2pConfig && listEquals(other.secret, secret) && listEquals(other.helpers, helpers) && other.helpersOnly == helpersOnly;

  @override
  int get hashCode => Object.hash(Object.hashAll(secret), Object.hashAll(helpers), helpersOnly);
}

/// One stream to or from another node: whole frames, in the order they were sent.
abstract class P2pStream {
  /// The node at the other end, as the core's handshake proved it: the other end holds that node's key. Never what the
  /// other end merely said, nor what this end asked to dial.
  String get nodeId;
  int get channel;

  /// Whether the other end opened it.
  bool get incoming;

  /// What the other end sends, a frame at a time: each whole, in the order sent, never more than [P2pNode.maxFrame]
  /// bytes (a longer one resets the stream, and nothing of it is handed over). What is not yet taken is bounded by flow
  /// control, not held without end. Done when the stream has closed, by either end or with the link; never delivered
  /// from within a call into the node.
  Stream<Uint8List> get frames;

  /// Sends a frame of at most [P2pNode.maxFrame] bytes. Fails with [P2pError], through the Future and never by
  /// throwing, where the stream has closed; a frame the other end's flow control holds back waits, it is not dropped.
  Future<void> add(Uint8List frame);

  /// Closes it: what was already sent on it is delivered, then the other end's [frames] is done. Closing twice is
  /// nothing. Fails only through the Future.
  Future<void> close();
}

/// A device's node. Every getter here, and [allow], [disallow], [openToAll], [networkChanged] and [pathTo], never
/// throws; [idOf], [start], [stop] and [open] fail only through their Futures. Events (on [state], [whereabouts],
/// [opened], [paths] and a stream's frames) are never delivered from within a call into the node. A release build logs
/// no node id, no address and nothing carried.
abstract class P2pNode {
  /// The longest frame a stream carries.
  static const maxFrame = 1 << 20;

  /// This device's node id, 64 hex digits; null until it has started once.
  String? get nodeId;

  /// The node id that [secret] (a node key, 32 bytes) makes, worked out without starting anything: a phone makes its
  /// device card with its node down. Fails only through the Future.
  Future<String> idOf(Uint8List secret);

  /// How the node stands ([P2pState]); whoever listens is told as it changes.
  ValueListenable<P2pState> get state;

  /// Why it is down, in words to show; null while it is not.
  String? get problem;

  /// Where this device can be found now, as it truly is; it changes as the network does. Null until the core knows,
  /// and while stopped. With [P2pConfig.helpersOnly], no address of its own; never a link helper but one of
  /// [P2pConfig.helpers].
  ValueListenable<Whereabouts?> get whereabouts;

  /// Starts it. Does nothing where it is up already with the same [config]; with another, it is stopped and started
  /// again. Who was allowed ([allow], [openToAll]) is kept across a stop and a start. Fails only through the Future.
  ///
  /// Nothing about it is public: no DNS or pkarr record, no DHT, no mDNS or other asking on the local network, and no
  /// relay or link helper is used but those in [P2pConfig.helpers]. Everything between two nodes is encrypted end to
  /// end, with no 0-RTT data.
  Future<void> start(P2pConfig config);

  /// Stops it: every stream closes, nothing can dial it, and it holds no socket and sends nothing until started again.
  /// A stop asked for while a start is under way wins: the node ends stopped, not up. A node costs a phone battery while
  /// it is up (it keeps its paths and its link helper warm every few seconds), so a phone runs one only while there is
  /// something to say. Fails only through the Future.
  Future<void> stop();

  /// The device's network changed (Wi-Fi to mobile data, back from sleep): the core looks at its paths again. Android
  /// doesn't tell native code by itself. Never throws.
  void networkChanged();

  /// Lets [nodeId] open streams to this device on [channels], in place of what it was allowed before (it replaces, it
  /// does not add). A node that was never allowed is turned away during the handshake, before anything it sends
  /// reaches the app, unless the channel is open to all ([openToAll]); and handshakes it turns away are turned away at
  /// a limited rate, so turning them away costs little. The core caps how many streams one node may hold open and how
  /// many it may open in a while, whatever it is allowed. Takes effect before it returns; never throws.
  void allow(String nodeId, Set<int> channels);

  /// Takes back what [allow] gave, and closes every stream with [nodeId], whichever end opened it, before it returns:
  /// nothing more of that node is handed over after. Never throws.
  void disallow(String nodeId);

  /// The channels anyone at all may open: a relay hosted here takes hub connections from devices it never heard of.
  /// None to begin with. Never throws.
  void openToAll(Set<int> channels);

  /// Opens a stream to [nodeId] on [channel], dialling it first where no link is up, by [hint] (where it last said it
  /// is) and by what the core already knows of it. Fails with [P2pError], through the Future, when it can't be reached
  /// within [timeout], when it turns this device away, or when this node isn't up; one way or the other it has ended by
  /// [timeout]. An address that is loopback, unspecified, multicast, broadcast or link-local (IPv4-mapped or not) is
  /// never dialled, whatever [hint] says; nor is a link helper not in [P2pConfig.helpers].
  Future<P2pStream> open(String nodeId, int channel, {Whereabouts? hint, Duration timeout = const Duration(seconds: 5)});

  /// The streams other nodes opened to this one, each already allowed, each [P2pStream.nodeId] proved.
  Stream<P2pStream> get opened;

  /// How the path to each linked node truly stands, each time that changes.
  Stream<P2pPath> get paths;

  /// How it stands with [nodeId] now; null where there is no link. Never throws.
  P2pPath? pathTo(String nodeId);
}

/// What a node says when it can't do what was asked.
class P2pError implements Exception {
  P2pError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Whether [s] is a node id: 64 hex digits, lower case.
bool isNodeId(Object? s) => s is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(s);
