/// Invites that waited on the relay for this phone's number, taken once the number is verified and offered here (Matt,
/// 2026-11-17: "a link that eventually follows through after they setup their account").
///
/// Someone texted an invite to a space or circle (lib/invites/text_invites.dart) left a sealed copy on the relay, kept
/// by a hash of this number. When the number is verified in Settings › Me (a code texted to it, relay/lib/handles.dart),
/// and whenever the app meets the relay again with one verified, those copies are fetched (the relay gives them only
/// to the install that verified that number), opened with a key made from the number, and offered: a circle among the
/// Circles tab's invites with its banner, a space on the "invited you" ring. Neither is joined until Join is pressed:
/// anyone who knows a number can leave an invite for it, so a space waits among Voice.offers, apart from the spaces,
/// as a circle waits among the circle invites. Who it says invited you is a friend's name only where the friend's
/// install signed it; otherwise it says someone who is not a friend. Each is dropped from the relay once it is held
/// here.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../circles/circles.dart';
import '../friends/buddies.dart';
import '../me/me.dart';
import '../net/hub_carrier.dart';
import '../net/net.dart';
import '../sms.dart';
import '../voice/channels.dart';
import '../voice/voice.dart';
import 'invite_relay.dart';
import 'invite_seal.dart';

/// Where an opened invite goes: the app's circles and spaces, or a test's.
abstract class InviteOffers {
  /// Offers [invite]; true once it is held here (offered, or the place already joined), so the relay's copy can go.
  bool offer(WaitingInvite invite);
}

/// Who an opened invite is said to be from: a friend's name where that friend's install signed it, never the name
/// written in it otherwise, since anyone who knows a number can write any name, and a stranger must not pass as a
/// friend.
String inviteFrom(WaitingInvite invite, {Buddies? buddies}) {
  final id = invite.signer;
  final friend = id == null ? null : (buddies ?? Buddies.instance).byId(id);
  if (friend != null && friend.state == 'yes') return friend.shown;
  return 'Someone (not a friend)';
}

/// The app's: a circle as an invite to Join or put off (Circles.offer), a space as an offer on the ring (Voice
/// .offerSpace), neither joined before Join is pressed.
class AppInviteOffers implements InviteOffers {
  const AppInviteOffers();

  @override
  bool offer(WaitingInvite invite) {
    final from = inviteFrom(invite);
    if (invite.circle) {
      final c = Circle.fromLink(invite.link);
      if (c == null) return true;
      final circles = Circles.instance;
      circles.offer(c, from: from, link: true);
      return circles.bySeed(c.seed) != null || circles.inviteFor(c.seed) != null;
    }
    final c = VoiceChannel.fromLink(invite.link);
    if (c == null) return true;
    return Voice.instance.offerSpace(c, from);
  }
}

class PendingInvites {
  PendingInvites({Me? me, InviteAsk? ask, InviteOffers? offers, DateTime Function()? now, Listenable? waitFor})
      : _me = me,
        _askOverride = ask,
        _offers = offers ?? const AppInviteOffers(),
        _now = now ?? DateTime.now,
        _waitFor = waitFor;

  /// The app's: nothing is offered before the circles have started (their first change, Circles.start, which comes
  /// after the spaces'), since an invite offered before would be written over as they read what was kept.
  static final PendingInvites instance = PendingInvites(waitFor: Circles.instance);

  final Me? _me;
  final InviteAsk? _askOverride;
  final InviteOffers _offers;
  final DateTime Function() _now;
  Listenable? _waitFor;

  Me get me => _me ?? Me.instance;

  /// Asked on the app's own connection: the install that verified the number is the one the relay hands them to.
  Future<Map<String, dynamic>> _ask(Map<String, Object?> what) {
    final ask = _askOverride;
    if (ask != null) return ask(what);
    final HubCarrier? hub = Net.instance.hub;
    if (hub == null) return Future.error(const InviteRelayError('The relay server can\'t be reached right now.'));
    return askHub(hub, what);
  }

  /// How often the relay is asked again while the app runs with a number verified.
  static const again = Duration(hours: 1);

  bool _started = false;
  bool _busy = false;
  String? _askedFor;
  DateTime? _askedAt;

  /// Listens for the number's verification, and for the relay being met with one verified. Once, as the app opens.
  void start() {
    if (_started) return;
    _started = true;
    me.addListener(_check);
    _waitFor?.addListener(_placesReady);
    _check();
  }

  /// What was waited for has changed for the first time (the circles have started): invites may be offered now.
  void _placesReady() {
    _waitFor?.removeListener(_placesReady);
    _waitFor = null;
    _check();
  }

  void _check() {
    if (_waitFor != null) return;
    // On a paired computer the number is the phone's, and the phone takes its invites.
    if (Sms.paired) return;
    final number = me.links['phone'];
    if (number == null || !me.ready || _busy) return;
    final at = _askedAt;
    if (_askedFor == number && at != null && _now().difference(at) < again) return;
    _busy = true;
    _askedFor = number;
    _askedAt = _now();
    unawaited(take(number).catchError((Object e) {
      if (kDebugMode) debugPrint('invites: not taken: $e');
      return 0;
    }).whenComplete(() => _busy = false));
  }

  /// Fetches what waits for [number], offers each, and drops those now held here from the relay. How many were
  /// offered.
  Future<int> take(String number) async {
    final e164 = inviteNumber(number);
    if (e164 == null) return 0;
    final h = numberHash(e164);
    final got = await _ask({'dir': 'invites', 'h': h});
    final drop = <String>[];
    var offered = 0;
    final entries = [
      for (final e in (got['list'] as List? ?? const []))
        if (e is Map && e['i'] is String && e['b'] is String) e,
    ];
    // Opened off the screen's isolate: each is a slow derivation (invite_seal.dart).
    final opened = await openInvites(e164, [for (final e in entries) e['b'] as String]);
    for (var i = 0; i < entries.length; i++) {
      final e = entries[i];
      final at = e['at'] is int ? DateTime.fromMillisecondsSinceEpoch(e['at'] as int) : null;
      final invite = opened[i]?.keptAt(at);
      // One that does not open was not sealed for this number: nothing to offer, and nothing worth keeping.
      if (invite == null) {
        drop.add(e['i'] as String);
        continue;
      }
      if (_offers.offer(invite)) {
        drop.add(e['i'] as String);
        offered++;
      }
    }
    if (drop.isNotEmpty) await _ask({'dir': 'invites-drop', 'h': h, 'ids': drop});
    return offered;
  }
}
