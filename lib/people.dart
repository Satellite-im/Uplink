import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'account/account.dart';
import 'app_state.dart';
import 'platform_info.dart';
import 'snooze.dart';
import 'sms.dart' show Sms;
import 'circles/circles.dart';
import 'friends/buddies.dart';
import 'friends/friends.dart';
import 'friends/groups.dart';
import 'me/lookup_budget.dart';
import 'me/me.dart';
import 'net/carrier.dart';
import 'net/home_record.dart' show splitUsername;
import 'net/hub_carrier.dart';
import 'net/name_watch.dart';
import 'net/net.dart';
import 'scheduled.dart';
import 'voice/channels.dart';

/// The app's own network, started where it runs here rather than on a paired phone: on the Android phone, on an
/// iPhone of its own, and on a computer with no phone linked (Matt, 2026-11-18: "a user can use the app without linking
/// the phone since some people may be joining just to enter circles or use telegram and signal but not SMS").
///
/// The routes to other phones (lib/net/net.dart), friends reached by them, groups, voice and the circles that ride
/// it, in that order; the accounts linked and the handles watched for (Settings › Me); and friends by username, heard
/// over the hub while any are kept or there is a username of one's own.
/// On a computer paired with a phone that has handed over its identity (lib/desktop/own_calls.dart): the routes, the
/// directory and friends by username run here, beside the phone, under the same identity; texts stay the phone's, and
/// voice and circles are started as a paired computer's (lib/desktop/main.dart).
void startOwnFriends(AppState app) {
  // Friends' words go by the routes ([Friends]): a friend by username's, here; a number's, still by the phone's texts.
  Net.instance.start(app).then((_) => Friends.instance.start(app)).then((_) => quietly(() => _checkRelay(app)));
  Me.instance.start(AppMeStore(app), Net.instance, () => Net.instance.hub, needHub: (yes) => Net.instance.want('me', yes));
  // An Uplink account of this computer's own, under the identity it took on (Matt, 2026-11-18: "there doesn't seem to be
  // a way to login on desktop just to claim a username, i would like to be able to link a session to a new account").
  Account.instance.start(AppMeStore(app));
  // Messages scheduled from Send (lib/scheduled.dart): sent as their times come, and any that came while closed.
  Scheduled.instance.start(app);
  // Conversations snoozed from Messages (lib/snooze.dart): back at the top as their times come, with a notification.
  startSnoozed(app);
  _hearBuddies();
}

/// Friends by username are heard over the hub: it is dialled while there are any, or a username of one's own, and
/// each friend is watched on it for their presence. Asked again whenever the friends or the username change.
void _hearBuddies() {
  void hear() {
    Net.instance.want('buddies', Buddies.instance.all.isNotEmpty || Me.instance.username != null);
    Net.instance.watchToo([for (final b in Buddies.instance.friends) if (!Buddies.instance.apart(b)) b.id]);
  }

  Buddies.instance.start().then((_) {
    hear();
    Buddies.instance.addListener(hear);
    Me.instance.addListener(hear);
  });
}

/// Starts everything about people where the app's own network runs whole (a phone, a device of its own): the
/// routes, then friends, groups, voice and circles in that order, each built on the one before; and beside them
/// who this is, the account, scheduled messages and friends by username.
void startPeople(AppState app) {
  // What checks the relay is started quietly: nothing it does can stop groups, voice and the circles starting after it.
  Net.instance.start(app).then((_) => Friends.instance.start(app)).then((_) => quietly(() => _checkRelay(app))).then((_) => Groups.instance.start()).then((_) => Voice.instance.start(app)).then((_) => Circles.instance.start(app));
  // The accounts linked and the handles watched for (Settings › Me): spoken of to the relay server only once one has
  // been.
  Me.instance.start(AppMeStore(app), Net.instance, () => Net.instance.hub, needHub: (yes) => Net.instance.want('me', yes));
  // An Uplink account (lib/account; Matt, 2026-11-17: "We need to have a way to login to existing accounts"): where this
  // device is signed in to one, the relay is asked whether it still is.
  Account.instance.start(AppMeStore(app));
  // Messages scheduled from Send (lib/scheduled.dart): sent as their times come, and any that came while closed.
  Scheduled.instance.start(app);
  // Conversations snoozed from Messages (lib/snooze.dart): back at the top as their times come, with a notification.
  startSnoozed(app);
  // Friends by username (lib/friends/buddies.dart): heard over the hub, so it is dialled while any are kept, and from
  // the moment there is a username of your own, so a first friend request reaches you (Matt, 2026-11-16: "We need a
  // way to add friends on the network by username on the contacts page and see friend requests").
  void hearBuddies() {
    Net.instance.want('buddies', Buddies.instance.all.isNotEmpty || Me.instance.username != null);
    // Friends by username watched on the hub, so their faces say when they are on (lib/presence.dart).
    Net.instance.watchToo([for (final b in Buddies.instance.friends) if (!Buddies.instance.apart(b)) b.id]);
  }

  Buddies.instance.start().then((_) {
    hearBuddies();
    Buddies.instance.addListener(hearBuddies);
    Me.instance.addListener(hearBuddies);
  });
}

/// Runs [step], and whatever goes wrong in it, at once or later, stays in it (the review, S5): what checks the relay sits
/// in the chain that starts groups, voice and the circles, and must never stop them.
@visibleForTesting
Future<void> quietly(FutureOr<void> Function() step) async {
  try {
    await step();
  } catch (_) {}
}

/// What checks the relay where the app runs its own network (docs/OPEN_NETWORK.md, section 3). Friends' unanswered
/// words are given to the ledger's comparing, to send again straight where a friend's device says they never came
/// (lib/net/ledger.dart; only where the build has the direct route). And the name watch (lib/net/name_watch.dart), which
/// needs no direct route: friends' usernames asked of the relay again once a day and this person's own at each
/// sign-in, the answers held against the keys that were added, and a friend told by every route where the relay gives
/// their username to another key.
void _checkRelay(AppState app) {
  Net.instance.addHolder(Friends.instance.heldFor);
  if (NameWatch.instance != null) return;
  // The relay's lookups are the account's, shared by all its devices: this one's place among those forward secrecy has
  // heard from this week, for the name watch's days and for the share of the lookups made of the app's own accord,
  // which the friend requests' checks take from too (LookupBudget).
  ({int index, int of}) share() {
    final me = Net.instance.id, fs = Net.instance.board?.fs;
    final devices = {HubCarrier.device, if (me != null && fs != null) ...fs.devicesOf(me)}.where((d) => d.isNotEmpty).toList()..sort();
    final at = devices.indexOf(HubCarrier.device);
    return at < 0 ? (index: 0, of: 1) : (index: at, of: devices.length);
  }

  LookupBudget.instance.share = share;
  final watch = NameWatch.instance = NameWatch(
    me: () => Net.instance.id,
    username: () => Me.instance.username,
    // Friends whose username is this relay's: one on another relay (name@relay, or whose record names another) is in
    // that relay's directory, which this relay's lookups don't answer for.
    friends: () => [for (final b in Buddies.instance.friends) if (splitUsername(b.username).relay == null && !Buddies.instance.elsewhere(b)) WatchedName(b.username, b.id, b.key)],
    whois: Me.instance.whois,
    // Which name this key holds on the relay: what the watch holds its own username to.
    held: Me.instance.heldName,
    // Each relay is its own directory.
    relay: () => Net.instance.hubUrl,
    share: share,
    lookups: LookupBudget.instance,
    tell: (id, envelope) async {
      final board = Net.instance.board, peer = Net.instance.byId(id);
      if (board != null && peer != null && peer.key != null) await board.sendEveryWay(peer, envelope);
    },
    read: (name) => app.choice(name, ''),
    // Its own bookkeeping, which no screen draws from the choices: nothing is drawn again for it.
    write: app.keep,
  );
  // This person's username claimed, changed or given up (Settings › Me): kept with the key and relay it was claimed
  // under, and what was said of the one before goes.
  var username = Me.instance.username;
  Me.instance.addListener(() {
    final now = Me.instance.username;
    if (now == username) return;
    username = now;
    if (now != null) {
      watch.claimed(now);
    } else {
      watch.usernameChanged();
    }
  });
  Net.instance.listen((r) {
    if (r.envelope.kind == NameWatch.kind) watch.heard(r.peer.id, r.envelope, sealed: r.sealed);
  });
  // Each sign-in to the relay, whichever relay is in use: its own username is asked again.
  HubCarrier? hub;
  var wasUp = false;
  void relay() {
    final up = hub?.state.value == CarrierState.up;
    if (up && !wasUp) unawaited(watch.signedIn());
    wasUp = up;
  }

  // The routes were set up anew: the relay's route listened to is the one there is now.
  void follow() {
    final now = Net.instance.hub;
    if (identical(now, hub)) return;
    hub?.state.removeListener(relay);
    hub = now;
    wasUp = false;
    now?.state.addListener(relay);
    relay();
  }

  Net.instance.addListener(follow);
  Buddies.instance.addListener(watch.friendsChanged);
  // Settings › Routes draws what it found again (Net.direct is what its pages listen to).
  watch.addListener(() => Net.instance.direct.value++);
  watch.start();
  follow();
}

/// Snoozes (lib/snooze.dart), each said when it ends: a notification on the phone that opens the app; on a computer,
/// which has none of its own, in the app while it is open (GMFB-36).
void startSnoozed(AppState app) {
  // Sms.notifyInbox puts one up on an Android phone's own app, and nowhere else.
  Snoozed.notifies = !Sms.remote && PlatformInfo.isAndroid;
  Snoozed.woke = (key, title) {
    final name = title.isEmpty ? 'A conversation' : title;
    if (Snoozed.notifies) {
      unawaited(Sms.instance.notifyInbox('snooze:$key', network: 'Snoozed', title: name, body: 'Back from snooze'));
    } else {
      Snoozed.back?.call(name);
    }
  };
  // One message's (GMFB-36): its words in the notification, which opens its conversation at it (lib/main.dart).
  Snoozed.wokeMessage = (chat, id, title, words) {
    final name = title.isEmpty ? 'A conversation' : title;
    if (Snoozed.notifies) {
      final said = words.length > 120 ? '${words.substring(0, 120)}…' : words;
      unawaited(Sms.instance.notifyInbox('snooze:${Snoozed.message(chat, id)}', network: 'Snoozed', title: name, body: said.isEmpty ? 'A snoozed message is back' : 'Snoozed: $said'));
    } else {
      Snoozed.back?.call('A message in $name');
    }
  };
  Snoozed.instance.start(app);
}
