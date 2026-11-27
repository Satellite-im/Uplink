import 'dart:ui' show AppLifecycleState;

import 'package:flutter/foundation.dart';

import '../net/hub_link.dart';

/// Whether the app is put away, for a phone's relay ([RelayHosting.appAway]): paused, hidden or gone, never only
/// `inactive`, which split screen, the notification shade and a call's screen are (found in the second review,
/// 2026-11-23: those stopped the relay a minute on).
bool hostAwayIn(AppLifecycleState state) => state == AppLifecycleState.paused || state == AppLifecycleState.hidden || state == AppLifecycleState.detached;

/// A relay hosted from this device, as the screens and the routes see it (docs/OPEN_NETWORK.md, section 5; Matt,
/// 2026-11-22: "i'd like everyone to be able to host a relay from their client"). What runs it is
/// lib/relay_host/relay_host_io.dart, the same hub gogho.st runs (relay/lib/hub.dart), on the Mac, Windows, Linux and
/// Android; an iPhone and a browser have none (lib/relay_host/relay_host.dart makes nothing there). Off unless the
/// person switches it on.
abstract class RelayHosting implements Listenable {
  /// The person's choice: host it or not. Kept with the app's choices (`relay_host_on`); off unless switched on.
  bool get on;

  /// How it stands now.
  HostState get state;

  /// Why it isn't running, or what of it isn't (the local network's door), in words to show; null where nothing is
  /// wrong.
  String? get problem;

  /// The relay's name (32 hex), made from its own key, which is kept in its folder: known once it has started once.
  String? get relayId;

  /// The public relay it stays linked to (`via`): Uplink's own, `wss://gogho.st/hub`, unless the person chose
  /// another ([setVia]).
  String get via;

  /// Chooses the public relay it stays linked to: a public relay's address (`relay.example.com`), or empty for Uplink's
  /// own. A problem in words where it isn't one; running, it starts again linked there.
  Future<String?> setVia(String typed);

  /// How many installs are signed in to it now, this app among them where it uses it.
  int get connections;

  /// Whether devices on the same network may use it, and the port they reach it at; the addresses they reach it by
  /// (`ws://address:port/hub`), while it listens.
  bool get lan;
  int get port;
  List<String> get lanUrls;

  /// This build has a direct route at all (lib/net/p2p), and Direct is switched on: then anyone given [directUrl] can
  /// reach it from anywhere, Direct on at their end too. The address, while the node is up.
  bool get directBuilt;
  bool get directOn;
  String? get directUrl;

  /// Whether people must give a pass phrase to use it.
  bool get hasPass;

  /// Whether this device's Direct knows a link helper: devices far away find it through one. None is known until a
  /// relay this app signs in to names one, so a relay hosted before any was named is found only by devices nearby.
  bool get directHelped;

  /// Whether this is a phone, where it runs only while the app is in use: not offered for this app there.
  bool get phone;

  /// How the link to [via] stands, said as [viaWords] says it.
  ViaLink get viaLink;

  /// The address this app reaches it by, in memory: `ghost-relay://<its name>?via=…`; null until it has a name.
  String? get ownUrl;

  /// Whether this app uses it now (Settings › Routes' relay is [ownUrl]).
  bool get inUse;

  /// The relay this app used before it moved onto this one, which it goes back to when this is switched off: empty for
  /// Uplink's own.
  String get usedBefore;

  /// Switches it on or off: on starts it (and keeps the choice), off stops it, moving this app back to the relay it
  /// used before where it was using this one. What it keeps is said in lib/relay_host/words.dart (keptWords).
  Future<void> setOn(bool on);

  /// Starts it where the person has it on and it isn't running: as the routes start.
  Future<void> startIfOn();

  /// Devices on the same network: their door opened or closed, and the port it listens at (a problem in words where
  /// the port is not one, or is taken).
  Future<void> setLan(bool on);
  Future<String?> setPort(int port);

  /// Sets the pass phrase (null or empty: none). Everyone signed in is signed out to sign in again with it, this app
  /// too.
  Future<void> setPass(String? phrase);

  /// Moves this app onto it (Settings › Routes' relay switch, with its home record's move), the relay it used before
  /// kept to go back to; a problem in words, or null where it moved.
  Future<String?> useHere();

  /// Whether [url] is this relay ([ownUrl], or its address over Direct).
  bool isMine(String url);

  /// A hub connection to it in memory, for this app ([HubDials.hosted]).
  Future<HubLink> dialHere();

  /// The pass phrase this app gives it, where it asks one.
  String? get ownPass;

  /// Direct was switched on or off in the routes (Net.setDirect), which made or dropped its P2p: channel 1 is opened on
  /// the new one, or closed. Without it a relay started with Direct off never opened it (found in the fourth review,
  /// 2026-11-23), and one kept across Direct off and on held the dropped one.
  void directChanged();

  /// The app put away, or back (Android stops it a minute after the app is put away, and starts it as it comes back).
  void appAway(bool away);

  /// The person signed out: stopped, switched off, and this app's relay set back to the one before it.
  Future<void> signedOut();

  /// The routes are going: stopped, the choice kept.
  Future<void> shutdown();
}

enum HostState {
  /// Not running: switched off, or stopped (the app put away on Android).
  off,
  starting,
  up,

  /// It could not start: [RelayHosting.problem] says why.
  failed,
}

/// How a hosted relay's link to its public relay stands ([RelayHosting.viaLink]).
@immutable
class ViaLink {
  const ViaLink(this.kind, {this.said, this.next});

  final ViaKind kind;

  /// What the public relay said, where it answered no.
  final String? said;

  /// When it is dialled again, where it isn't linked.
  final DateTime? next;
}

enum ViaKind {
  /// The relay isn't running.
  off,

  /// Dialling it, or about to.
  linking,

  /// Linked, and the public relay lets it stay: its people are reached through it.
  stays,

  /// Linked, and the public relay doesn't let relays hosted from an app stay: friends elsewhere can't reach its people.
  linkedOnly,

  /// It answered, and won't link: its relays-that-talk is off, or its keeper doesn't take this one.
  refused,

  /// Nothing answered.
  down,
}
