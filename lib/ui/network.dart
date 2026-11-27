import 'package:flutter/widgets.dart';
import 'package:glacier/glacier.dart';

import '../art/app_icon.dart';
import '../art/lucide.g.dart';
import '../friends/buddies.dart';
import '../friends/groups.dart';
import '../kit/settings_kit.dart';
import '../kit/settings_type.dart';
import '../net/carrier.dart';
import '../net/hub_link.dart';
import '../net/lan/lan_carrier.dart';
import '../net/lan/lan_ground.dart' show lanGroundMissing;
import '../net/ledger.dart';
import '../net/name_watch.dart';
import '../net/net.dart';
import '../net/hub_carrier.dart' show HubRelay;
import '../net/p2p/node.dart';
import 'name_watch_words.dart';
import '../net/p2p/p2p.dart';
import '../net/p2p/p2p_carrier.dart' show P2pCarrier;
import '../net/switchboard.dart' show RouteUse, Switchboard;
import '../net/relay_choice.dart';
import 'common.dart';
import 'compose.dart';
import 'relay_host_section.dart';
import '../relay_host/words.dart' show joinHostedWords;
import 'settings.dart';
import 'shell.dart';
import '../l10n/words.dart';

/// What one of the people the routes reach is called in Settings › Network: their name, else their address, else (no
/// address of theirs being known here: a member of a group, say, or someone who asked to be a friend) the group they are
/// in, else the start of their install's name. An address that is empty is none (found in review, 2026-11-23: their
/// row was blank).
String peerLabel(Peer p, {Iterable<Group>? groups}) {
  final name = p.name?.trim() ?? '', address = p.address?.trim() ?? '';
  if (name.isNotEmpty) return name;
  if (address.isNotEmpty) return address;
  final group = (groups ?? Groups.instance.all).where((g) => !g.gone && g.member(p.id) != null).firstOrNull;
  if (group != null) return 'A member of ${group.title}';
  return p.id.length > 8 ? p.id.substring(0, 8) : p.id;
}

/// How the network stands, in a line: Settings' row for it.
String networkSummary() {
  final net = Net.instance;
  if (net.error != null) return 'Not set up';
  if (!net.on) return 'Off';
  final people = net.people.length;
  if (people == 0) return 'Nobody to reach yet';
  final up = net.board?.carriers.where((c) => c.state.value == CarrierState.up).length ?? 0;
  return '${people == 1 ? '1 person' : '$people people'} · ${up == 1 ? '1 route' : '$up routes'} ready';
}

/// What an invitation says: where to get the app, in words a person would send. When they have it and the two
/// phones text each other, the app offers to exchange keys, and that is what makes them reachable by the routes.
const inviteText = 'Join me on Uplink: calls and private chats straight between our phones. Get it at https://gogho.st';

/// Each route's icon in Settings › Routes.
LucideIcon _routeIcon(String id) => switch (id) { 'hub' => Lucide.globe, 'sms' => Lucide.messageSquare, 'lan' => Lucide.wifi, P2pCarrier.routeId => Lucide.link2, _ => Lucide.network };

/// How one route stands, for under its name: [on] is the network's own switch, [off] the route's switched off, and
/// [anyone] whether there is somebody to reach yet.
String _routeLine(Carrier c, {required bool on, required bool anyone, required bool off}) {
  if (off || !on) return 'Off';
  if (!anyone) return 'Waiting until there is someone to reach';
  return switch (c.state.value) {
    CarrierState.up => 'Ready',
    CarrierState.connecting => 'Connecting…',
    CarrierState.down => c.problem ?? 'Not working now',
    CarrierState.off => 'Off',
  };
}

/// How many devices the direct route knows of, in words (Settings › Routes › Direct).
String directKnownWords(int friends) => switch (friends) {
      0 => 'No friend\'s device known yet',
      1 => 'Knows 1 friend\'s device',
      _ => 'Knows $friends friends\' devices',
    };

/// Under [directKnownWords]: this account's own other devices, and how a device comes to be known.
String directKnownHint(int own) =>
    '${own == 0 ? '' : own == 1 ? 'And 1 other device of your own. ' : 'And $own other devices of your own. '}A device is known once it and this one have told each other they are here, which they do through the relay server.';

/// How many devices are linked now, in words, and under it whether each link is straight or through a link helper.
String directLinkedWords(int linked) => switch (linked) {
      0 => 'Not linked to any now',
      1 => 'Linked to 1 device now',
      _ => 'Linked to $linked devices now',
    };

/// The line under [directLinkedWords]: how many of the links are straight and how many go through a link helper; with
/// none, when a link is made at all.
String directLinkedHint(Iterable<P2pPathKind> links) {
  final straight = links.where((k) => k == P2pPathKind.direct).length, helped = links.where((k) => k == P2pPathKind.helper).length;
  if (links.isEmpty) return 'A link is made when the relay server can\'t carry something, and let go when nothing has been said on it for a while.';
  final parts = [if (straight > 0) '$straight straight', if (helped > 0) '$helped through a link helper'];
  return parts.isEmpty ? 'Finding the way.' : '${parts.join(', ')}.';
}

/// What "Only through link helpers" means, under its switch.
const directHelpersOnlyHint = 'Friends\' devices then see the link helper\'s address and not this device\'s. It is slower.';

/// What switching Direct on means, said before it is on (Settings › Routes › Direct, under its title).
const directOffWords =
    'Switched on, this device links straight with your own devices and your friends\' when the relay server can\'t carry something, and checks what the relay says against what they say. Only those devices are told where this one is, and they learn its network address.';

/// What Direct does, said while it is on.
const directOnWords = 'Straight between devices when the relay server can\'t carry something. This device links only with your own devices and your friends\', and only they are told where it is: they learn its network address.';

/// What a link helper is, and what it sees, under the Direct section either way.
const directHelperWords =
    'A link helper is a server that helps two devices find each other and passes their sealed packets along where no straight path can be made. It sees which devices link and how much they send, never who they are or what is said.';

/// The relay in use names no link helper (a relay of one's own, or one that hasn't been given any): what that costs,
/// rather than a helper made up in its place. The row's label, and the line under it.
const directNoHelperLabel = 'The relay server names no link helper';
String directNoHelperHint({required bool helpersOnly}) => helpersOnly
    ? 'So nothing links while "Only through link helpers" is on.'
    : 'So only devices that can reach each other as they are link up, such as two on the same network: devices behind most home routers can\'t link.';

/// Settings › Routes › Direct (docs/OPEN_NETWORK.md, section 2; Matt, 2026-11-22: "p2p delivery with the relay as a
/// primary source but have p2p as a secondary back up"): what the direct route knows and holds now, and its one
/// choice. The route's own row, with its switch, is with the other routes above.
PaneSection directSection(BuildContext context, P2p p2p) {
  Widget icon(LucideIcon i) => AppIcon(i, size: 18);
  final links = p2p.carrier.links;
  // One device, however many streams or names it is linked under.
  final kinds = {for (final l in links) l.nodeId: l.kind}.values;
  return PaneSection(
    title: 'Direct',
    description: const Text(directOnWords),
    footer: const Text(directHelperWords),
    children: [
      SettingRow(
        key: const ValueKey('direct-known'),
        icon: icon(Lucide.users),
        label: directKnownWords(p2p.friendsDevices),
        hint: Text(directKnownHint(p2p.ownDevices)),
      ),
      SettingRow(
        key: const ValueKey('direct-linked'),
        icon: icon(Lucide.link),
        label: directLinkedWords(kinds.length),
        hint: Text(directLinkedHint(kinds)),
      ),
      SettingRow(
        key: const ValueKey('direct-helpers-only'),
        icon: icon(Lucide.eyeOff),
        label: 'Only through link helpers',
        hint: const Text(directHelpersOnlyHint),
        control: GlacierSwitch(checked: p2p.helpersOnly, onCheckedChange: p2p.setHelpersOnly, ariaLabel: 'Only through link helpers'),
      ),
      if (p2p.helpers.isEmpty)
        SettingRow(
          key: const ValueKey('direct-no-helpers'),
          icon: icon(Lucide.info),
          label: directNoHelperLabel,
          hint: Text(directNoHelperHint(helpersOnly: p2p.helpersOnly)),
        ),
    ],
  );
}

/// Settings › Routes › Direct before Direct is switched on: what switching it on means, "Only through link helpers",
/// which can be chosen first, and where the relay in use names no link helper, what that costs. Nothing of the direct
/// network is made to draw it.
PaneSection directOffSection(BuildContext context, Net net) {
  Widget icon(LucideIcon i) => AppIcon(i, size: 18);
  final helpers = net.relayHelpers;
  return PaneSection(
    title: 'Direct',
    description: const Text(directOffWords),
    footer: const Text(directHelperWords),
    children: [
      SettingRow(
        key: const ValueKey('direct-helpers-only'),
        icon: icon(Lucide.eyeOff),
        label: 'Only through link helpers',
        hint: const Text(directHelpersOnlyHint),
        control: GlacierSwitch(checked: net.helpersOnly, onCheckedChange: net.setHelpersOnly, ariaLabel: 'Only through link helpers'),
      ),
      if (helpers != null && helpers.isEmpty)
        SettingRow(
          key: const ValueKey('direct-no-helpers'),
          icon: icon(Lucide.info),
          label: directNoHelperLabel,
          hint: Text(directNoHelperHint(helpersOnly: net.helpersOnly)),
        ),
    ],
  );
}

/// Settings › Routes' row for Direct while its route is not made (switched off; switched on a moment ago; or on, and it
/// could not be made): the same name, words and switch as the route's own row, drawn from no route at all.
Widget _directOffRow(Net net, {required Widget icon}) {
  final on = net.directOn;
  return SettingRow(
    key: const ValueKey('route-${P2pCarrier.routeId}'),
    icon: icon,
    label: P2pCarrier.label,
    hint: Text('${!net.on || !on ? 'Off' : net.directProblem != null ? 'Not working on this device' : 'Starting…'}\n${P2pCarrier.aboutWords}'),
    control: GlacierSwitch(checked: on, onCheckedChange: (v) => net.setRoute(P2pCarrier.routeId, v), ariaLabel: P2pCarrier.label),
  );
}

/// The routes' ids as Settings › Routes lists them, in the switchboard's order: those on [board], and Direct where it
/// is offered and its route is not made ([standIn]), in its place after the relay's.
List<String> _routeIds(Switchboard board, {required bool standIn}) {
  final ids = [for (final c in board.carriers) c.id];
  if (!standIn || ids.contains(P2pCarrier.routeId)) return ids;
  int at(String id) {
    final i = board.order.indexOf(id);
    return i < 0 ? board.order.length : i;
  }

  final mine = at(P2pCarrier.routeId);
  final i = ids.indexWhere((id) => at(id) > mine);
  return ids..insert(i < 0 ? ids.length : i, P2pCarrier.routeId);
}

String _ago(DateTime at) {
  final s = DateTime.now().difference(at).inSeconds;
  if (s < 60) return 'just now';
  if (s < 3600) return '${s ~/ 60} min ago';
  return '${s ~/ 3600} h ago';
}

// --- The local network route (GMFB-24; lib/net/lan) -----------------------------------------------------------------

/// Under the list of routes: what this build has no route for, and why; null where there is nothing to say.
String? routesFooter({required bool directOffered, required bool lanOffered, String? lanMissing}) {
  final parts = [
    if (!directOffered) 'A direct route between devices, with no server, isn\'t in this build yet.',
    if (!lanOffered) 'No local network route here: ${lanMissing ?? 'this build has none.'}',
  ];
  return parts.isEmpty ? null : parts.join(' ');
}

/// How many of the people's devices are heard on this network, and how many are linked, in words.
String lanFoundWords(int seen) => switch (seen) {
      0 => 'Nobody\'s device found on this network yet',
      1 => 'Found 1 device on this network',
      _ => 'Found $seen devices on this network',
    };
String lanLinkedWords(int linked) => switch (linked) {
      0 => 'Not linked to any now',
      1 => 'Linked to 1 device now',
      _ => 'Linked to $linked devices now',
    };

/// Under the Local network section: what the device says to the network, who can tell whose it is, and what Invisible
/// changes and doesn't (found in review, 2026-11-26: it said "Nothing is said while you are shown as Invisible", and
/// the device went on saying it was here under the same name, from the same address).
const lanSaysWords =
    'Every few seconds this device says it is here in a way only your own devices and your friends\' can recognise. Anyone else on the network sees that a copy of the app is at this address, never who you are. While you are shown as Invisible only your own devices can tell it is yours: it starts over under a new name, so your friends\' devices lose the one they knew, but a copy of the app is still seen at this address.';

/// Under [lanFoundWords]: whose devices are looked for, and when they are found.
const lanFoundHint =
    'Your own devices and your friends\', while they have Uplink open on the same Wi-Fi or wired network with this route switched on. A device is found within a few seconds of joining the network.';

/// Settings › Routes › Local network (GMFB-24): what the route finds and holds on this network now. Its own row, with
/// its switch, is with the other routes above. [nameOf] names a person by their install's name.
PaneSection lanSection(BuildContext context, LanCarrier lan, {required String Function(String id) nameOf}) {
  Widget icon(LucideIcon i) => AppIcon(i, size: 18);
  final links = lan.links;
  return PaneSection(
    title: 'Local network',
    description: const Tr('Straight between devices on the network this one is on, with no server and no internet. Used when the relay server can\'t carry something, and by itself where there is no internet at all.'),
    footer: const Text(lanSaysWords),
    children: [
      SettingRow(key: const ValueKey('lan-seen'), icon: icon(Lucide.wifi), label: lanFoundWords(lan.seen), hint: const Text(lanFoundHint)),
      SettingRow(
        key: const ValueKey('lan-linked'),
        icon: icon(Lucide.link2),
        label: lanLinkedWords(links.length),
        hint: links.isEmpty ? null : Text([for (final l in links) '${nameOf(l.peer)} at ${l.address}'].join('\n')),
      ),
    ],
  );
}

// --- Which route each conversation is on (GMFB-24) -------------------------------------------------------------------

/// A route's name as Settings › Routes says which one carried something: the names the routes go by, whether or not
/// the route is still there (Direct switched off since, say).
String routeName(String id) => switch (id) { 'hub' => 'Relay server', P2pCarrier.routeId => P2pCarrier.label, 'sms' => 'SMS', 'lan' => 'Local network', _ => id };

/// What went to someone and came from them, and by which route, as the line under their name says it.
String routeUseWords(RouteUse u, {required int now}) {
  final sent = u.sentBy == null ? 'Nothing sent lately' : 'Last sent by ${routeName(u.sentBy!)}, ${agoWords(u.sentAt!.millisecondsSinceEpoch, now)}';
  final came = u.cameBy == null ? 'nothing has come lately' : 'last came by ${routeName(u.cameBy!)}, ${agoWords(u.cameAt!.millisecondsSinceEpoch, now)}';
  return '$sent; $came.';
}

/// The route [u] was on last, whichever way: the one that brought something where that was later than what was sent.
String routeLastOf(RouteUse u) => u.cameBy != null && (u.sentAt == null || u.cameAt!.isAfter(u.sentAt!)) ? u.cameBy! : u.sentBy ?? '';

/// A group's line: each of its people who has been sent to or heard from with the route they were last on, in the
/// group's own order, then how many of the rest there are. [members] is each one's name with what is known of them.
String groupRouteWords(List<(String name, RouteUse? use)> members) {
  final known = [for (final (name, use) in members) if (use != null) '$name by ${routeName(routeLastOf(use))}'];
  final rest = members.length - known.length;
  final others = rest == 0 ? '' : known.isEmpty ? '' : '; nothing lately to or from ${rest == 1 ? '1 other' : '$rest others'}';
  return '${known.join(', ')}$others.';
}

/// The most conversations "Which route each conversation is on" lists: those used last.
const routesUsedShown = 20;

/// Settings › Routes › Which route each conversation is on (GMFB-24: "Settings › Network shows which route each
/// conversation is using"): each conversation with someone the routes reach, newest first, with the route that last
/// carried something each way and when. A person's own conversation is their row; a group of friends goes person by
/// person, since each of its people is reached by a route of their own ([groups], those this phone is in). From what
/// the switchboard saw ([Switchboard.used]), which the app keeps on this device from one run to the next
/// (lib/net/routes_kept.dart). [nameOf] names a person by their install's name.
PaneSection routesUsedSection(BuildContext context, Map<String, RouteUse> used, {required String Function(String id) nameOf, Iterable<Group> groups = const [], int? now}) {
  Widget icon(LucideIcon i) => AppIcon(i, size: 18);
  final at = now ?? DateTime.now().millisecondsSinceEpoch;
  // Each row with when anything last went or came in it, to put the newest first.
  final rows = <(DateTime, Widget)>[
    for (final e in used.entries)
      (
        e.value.last,
        SettingRow(
          key: ValueKey('used-${e.key}'),
          icon: icon(_routeIcon(routeLastOf(e.value))),
          label: nameOf(e.key),
          hint: Text(routeUseWords(e.value, now: at)),
        ),
      ),
  ];
  for (final g in groups) {
    if (g.gone) continue;
    final members = [for (final m in g.others) (m.label, used[m.id])];
    final uses = [for (final (_, u) in members) ?u];
    if (uses.isEmpty) continue;
    final last = uses.reduce((a, b) => a.last.isAfter(b.last) ? a : b);
    rows.add((
      last.last,
      SettingRow(
        key: ValueKey('used-group-${g.id}'),
        icon: icon(Lucide.users),
        label: g.title,
        hint: Text(groupRouteWords(members)),
      ),
    ));
  }
  rows.sort((a, b) => b.$1.compareTo(a.$1));
  return PaneSection(
    title: 'Which route each conversation is on',
    description: const Tr('The route that last carried something to each person, and the one that last brought something from them. A group goes person by person: each of its people is reached by a route of their own.'),
    footer: Text(
        '${rows.length > routesUsedShown ? 'The $routesUsedShown used last. ' : ''}Circles and spaces always go by the relay server they were made on, and texts by the phone\'s carrier. Kept on this device only, out of any backup, for a week, and deleted when you sign out.'),
    children: [for (final (_, row) in rows.take(routesUsedShown)) row],
  );
}

/// Whom Settings › Routes names by [id], an install's name: this account's own other devices, else as the routes know
/// them ([peerLabel]), else the start of the name.
String _usedName(String id) {
  final net = Net.instance;
  if (id == net.id) return 'Your other devices';
  final p = net.byId(id);
  if (p != null) return peerLabel(p);
  return id.length > 8 ? id.substring(0, 8) : id;
}

// --- Checking the relay (docs/OPEN_NETWORK.md, section 3) -----------------------------------------------------------

/// How long ago [at] was from [now] (both ms), in words.
String agoWords(int at, int now) {
  final s = (now - at) ~/ 1000;
  if (s < 60) return 'just now';
  if (s < 3600) return '${s ~/ 60} min ago';
  if (s < 2 * 86400) return '${s ~/ 3600} h ago';
  return '${s ~/ 86400} days ago';
}

/// The day [ms] fell on, as a row says it: "21 Nov".
String dayWords(int ms) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.day} ${months[d.month - 1]}';
}

/// When the relay was last checked over direct links, and with how many friends' devices.
String relayCheckedWords(int at, int devices, {required int now}) =>
    at <= 0 ? 'Not checked yet' : 'Last checked ${agoWords(at, now)}, with ${devices == 1 ? '1 device' : '$devices devices'}';

/// How many messages both ends agreed on this week.
String relayMatchedWords(int matched) => '${matched == 1 ? '1 message' : '$matched messages'} matched this week';

/// How many had to come straight with the relay not at fault.
/// How many came straight after the relay didn't bring them, and of those how many were lost when it started again: only
/// what did come straight is counted (the review, D7).
String relayMadeUpWords(int madeUp, {int restarts = 0}) => madeUp == 0
    ? 'None had to come straight.'
    : '${madeUp == 1 ? '1 came' : '$madeUp came'} straight after the relay didn\'t bring ${madeUp == 1 ? 'it' : 'them'}${restarts == 0 ? '' : restarts == madeUp ? ', lost when it started again' : ' ($restarts lost when it started again)'}.';

/// One thing the relay got wrong, said as whose word it is (the review, D5): what the relay told the friend [who]'s
/// device, held to what happened here, put down only once the message came straight.
String relayWrongWords(LedgerWrong w, String who) => switch (w.kind) {
      LedgerWrongKind.passed => '$who\'s device says the relay passed on a message to you, and it never came by the relay',
      LedgerWrongKind.kept => '$who\'s device says the relay kept a message for you, and it never handed it over',
      LedgerWrongKind.away => '$who\'s device says the relay told it you were away while you were connected',
      LedgerWrongKind.gone => 'The relay said $who was gone while their device said it was connected',
    };

/// What the name watch does, in a line, and when it last asked.
String nameWatchWords(int friends) => friends == 0 ? 'No friends added by username yet' : 'Asks the relay about ${friends == 1 ? '1 friend\'s username' : '$friends friends\' usernames'} each day';

/// The line under [nameWatchWords]; [lastAsked] is 0 or less where nothing was asked yet.
String nameWatchHint(int lastAsked, {required int now}) => lastAsked <= 0
    ? 'Each is asked at a time of its own through the day, and the answer held against the key you added.'
    : 'Last asked ${agoWords(lastAsked, now)}. Each answer is held against the key you added; nothing the relay says changes who your friends are.';

/// Settings › Routes › Checking the relay (docs/OPEN_NETWORK.md, section 3; Matt, 2026-11-22: "p2p as a secondary back
/// up that validates everything our relay says"). Per relay, plainly: when it was last checked over direct links and
/// with how many devices, how many messages matched and how many were made up for, each thing it got wrong with its
/// day, and "Check now" (once a minute at most). Then the name watch, which needs no direct route. In a build with no
/// direct route ([ledger] null) it says the relay is checked only by the name watch, shows that alone, and dials
/// nothing.
PaneSection relayCheckSection(BuildContext context, {required Ledger? ledger, required LedgerCheck? check, required NameWatch? watch, required String relay, bool directOn = true, bool directOffered = false, String Function(String id)? nameOf, int? now}) {
  Widget icon(LucideIcon i) => AppIcon(i, size: 18);
  final at = now ?? DateTime.now().millisecondsSinceEpoch;
  String who(String id) {
    final n = nameOf?.call(id);
    return n == null || n.isEmpty ? (id.length >= 6 ? id.substring(0, 6) : id) : n;
  }

  final compares = ledger != null && check != null;
  final rows = <Widget>[];
  if (compares) {
    final records = ledger.relays;
    final r = records[relay];
    rows.add(SettingRow(
      key: const ValueKey('relay-checked'),
      icon: icon(Lucide.shieldCheck),
      label: relayCheckedWords(r?.lastChecked ?? 0, r?.devices ?? 0, now: at),
      hint: Text('Of ${relayInUseWords(relay)}, over direct links with your friends\' devices.'),
    ));
    if (r != null && r.lastChecked > 0) {
      rows.add(SettingRow(
        key: const ValueKey('relay-matched'),
        icon: icon(Lucide.check),
        label: relayMatchedWords(r.matched(at)),
        hint: Text(relayMadeUpWords(r.madeUp(at), restarts: r.restarts(at))),
      ));
      final wrong = r.wrong.reversed.toList();
      if (wrong.isEmpty) {
        rows.add(SettingRow(key: const ValueKey('relay-wrong-none'), icon: icon(Lucide.circleCheck), label: 'It got nothing wrong'));
      }
      for (final (i, w) in wrong.indexed) {
        rows.add(SettingRow(key: ValueKey('relay-wrong-$i'), icon: icon(Lucide.circleAlert), label: relayWrongWords(w, who(w.friend)), hint: Text(dayWords(w.at))));
      }
    }
    // Relays this device used before, with what was found of them.
    for (final o in records.values.where((o) => o.url != relay)) {
      rows.add(SettingRow(
        key: ValueKey('relay-before-${o.url}'),
        icon: icon(Lucide.history),
        label: 'Before: ${relayInUseWords(o.url)}',
        hint: Text('${relayCheckedWords(o.lastChecked, o.devices, now: at)}. ${relayMatchedWords(o.matched(at))}; ${o.wrong.length == 1 ? '1 thing' : '${o.wrong.length} things'} wrong.'),
      ));
    }
    final may = directOn && check.canCheckNow;
    rows.add(SettingRow(
      key: const ValueKey('relay-check-now'),
      icon: icon(Lucide.refreshCw),
      label: 'Check now',
      hint: Text(!directOn
          ? 'Switch Direct on above to compare.'
          : may
              ? 'Dials the friends the relay says are here, and compares.'
              : 'Checked a moment ago. Again in a minute.'),
      disabled: !may,
      onPress: may
          ? () async {
              final n = await check.checkNow();
              if (!context.mounted) return;
              toast(context, n == 0 ? 'Nobody the relay says is here can be compared with now' : 'Comparing with ${n == 1 ? '1 friend' : '$n friends'}');
            }
          : null,
    ));
  }
  // The name watch: what needs no direct route.
  if (watch != null) {
    rows.add(SettingRow(
      key: const ValueKey('names-watched'),
      icon: icon(Lucide.atSign),
      label: nameWatchWords(watch.watching),
      hint: Text(nameWatchHint(watch.lastAsked, now: at)),
    ));
    // In the rows' own ink, with what usually causes each said (the review, M1 and M2).
    final own = watch.own;
    if (own != null) rows.add(SettingRow(key: const ValueKey('names-own'), icon: icon(Lucide.info), label: ownNameWords(own), hint: Text('${dayWords(own.at)}. ${ownNameHint(own)}')));
    for (final (i, t) in watch.toldMe.reversed.indexed) {
      rows.add(SettingRow(key: ValueKey('names-told-$i'), icon: icon(Lucide.info), label: toldWords(who(t.by ?? ''), t.username), hint: Text('${dayWords(t.at)}. $toldHint')));
    }
    for (final (i, c) in watch.changes.indexed) {
      rows.add(SettingRow(key: ValueKey('names-changed-$i'), icon: icon(Lucide.info), label: friendNameChangedLabel(c.change.username), hint: Text('${dayWords(c.change.at)}. ${friendNameChangedHint(who(c.friend))}')));
    }
  }
  return PaneSection(
    title: 'Checking the relay',
    description: Text(compares
        ? 'Your devices and your friends\' compare what went between them, over direct links, to find anything the relay dropped or kept back. Friends\' usernames are asked of it again each day.'
        : directOffered
            ? 'Direct is off, so the relay is checked only by the name watch: friends\' usernames are asked of it again each day, and your own each time you connect. Switch Direct on above to compare what went between your devices and your friends\' over direct links too.'
            : 'This device has no direct route, so the relay is checked only by the name watch: friends\' usernames are asked of it again each day, and your own each time you connect. Nothing is dialled.'),
    footer: Text(compares
        ? 'What is compared is which messages went and came, and when: never their words. It goes only to the friend it concerns, sealed, over a direct link.'
        : 'Only the relay you use is asked. A friend whose username it now gives to another account is told, sealed, through the relay.'),
    children: rows,
  );
}

/// Settings › Network: the app's routes (Matt, 2026-11-14: "implement a full relay system for the app that's
/// replacable and swappable ... The goal will be to have multiple sources to feed data to eachother from wifi
/// locally, p2p, internet, sms, etc"). Each route with how it stands and a switch, the relay server's address, the
/// people the routes reach with a test to each, and what the routes last did.
List<Widget> networkPane(BuildContext context, SettingsModel m) {
  final net = Net.instance;
  final board = net.board;
  Widget icon(LucideIcon i) => AppIcon(i, size: 18);
  final anyone = net.people.isNotEmpty;
  // What this build has no route for, under the list of routes.
  final routesNote = routesFooter(directOffered: net.directOffered, lanOffered: net.lan != null, lanMissing: lanGroundMissing());

  // Sends a test to one person (by the route [only], where named) and says how it went.
  Future<void> test(Peer p, {String? only}) async {
    final r = await net.test(p, only: only);
    if (!context.mounted) return;
    final d = r.delivery;
    final by = board?.carrier(d.via ?? '')?.name ?? d.via;
    toast(
      context,
      !d.sent
          ? 'Couldn\'t send it: ${d.tried.join('; ')}'
          : d.acked
              ? 'Reached them by $by in ${r.took.inMilliseconds} ms'
              : d.handed == Handed.held
                  ? 'They are away: the relay server is keeping it for them'
                  : 'Sent by $by. Their phone shows it under Settings › Routes.',
      tone: d.sent ? GlacierToastTone.neutral : GlacierToastTone.danger,
    );
  }

  return [
    PaneSection(
      footer: const Tr('It works with the people encryption is on with: exchanging keys by text is what introduces two phones. Nothing is sent anywhere until there is one. Everything that crosses is sealed between the two phones.'),
      children: [
        SettingRow(
          icon: icon(Lucide.network),
          label: 'Reach other phones with the app directly',
          hint: const Tr('For calls, and for what a text cannot carry.'),
          control: GlacierSwitch(checked: net.on, onCheckedChange: net.setOn, ariaLabel: 'Reach other phones with the app directly'),
        ),
      ],
    ),
    if (net.error != null)
      PaneSection(title: 'Not set up', children: [
        SettingRow(icon: icon(Lucide.circleAlert), label: 'The routes could not be set up', hint: Text(net.error!)),
      ]),
    if (board != null)
      PaneSection(
        title: 'Routes',
        description: const Tr('The ways this phone reaches another, tried from the top. One that fails or gets no answer gives way to the next.'),
        footer: routesNote == null ? null : Text(routesNote),
        children: [
          // Direct among them wherever the build offers it: its route's own row once it is made, else the same row
          // drawn from nothing, switched off (or on and not working), until the person switches it on.
          for (final id in _routeIds(board, standIn: net.directOffered))
            if (board.carrier(id) case final c?)
              SettingRow(
                key: ValueKey('route-${c.id}'),
                icon: icon(_routeIcon(c.id)),
                label: c.name,
                hint: Text('${_routeLine(c, on: net.on, anyone: anyone, off: board.off.contains(c.id))}\n${c.about}'),
                control: GlacierSwitch(checked: !board.off.contains(c.id), onCheckedChange: (v) => net.setRoute(c.id, v), ariaLabel: c.name),
              )
            else
              _directOffRow(net, icon: icon(_routeIcon(id))),
        ],
      ),
    if (board != null && net.p2p != null) directSection(context, net.p2p!),
    // Offered and not on: what switching it on means, before it is.
    if (board != null && net.p2p == null && net.directOffered && net.directProblem == null) directOffSection(context, net),
    // A build with the direct route whose core could not be started (a library missing, or built for another machine):
    // the other routes go on, and this says why there is no Direct among them.
    if (board != null && net.p2p == null && net.directProblem != null)
      PaneSection(title: 'Direct', children: [
        SettingRow(key: const ValueKey('direct-problem'), icon: icon(Lucide.circleAlert), label: 'Direct isn\'t working on this device', hint: Text(net.directProblem!)),
      ]),
    // The local network route, while it is on: who is seen and linked on this network now (GMFB-24).
    if (board != null && net.lan != null && net.lanOn) lanSection(context, net.lan!, nameOf: _usedName),
    // Checking the relay: what comparing over direct links found, and the name watch, which needs no direct route.
    if (board != null) relayCheckSection(context, ledger: net.ledger, check: net.check, watch: NameWatch.instance, relay: net.hubUrl, directOn: net.p2p?.on ?? false, directOffered: net.directOffered && net.directProblem == null, nameOf: _friendName),
    if (board != null && net.hub != null)
      PaneSection(
        title: 'Relay server',
        description: const Tr('It sees which installs talk and when, never what they say. You can run your own and use it here instead of ours.'),
        footer: const Text(relayLimitsWords),
        children: [
          SettingRow(
            key: const ValueKey('relay-in-use'),
            icon: icon(Lucide.globe),
            label: relayInUseLabel(net),
            hint: Text('In use · ${_hubLine(net)}'),
          ),
          // A relay that runs in someone else's app (it said so in its hello; lib/relay_host): what its keeper sees, said
          // for as long as this app is on it, not only as it joined.
          if (net.hub!.hosted && !(net.relayHost?.isMine(net.hubUrl) ?? false))
            SettingRow(key: const ValueKey('relay-hosted'), icon: icon(Lucide.info), label: 'It runs in someone\'s app', hint: const Text(joinHostedWords)),
          // Whether this relay passes messages to other relays, as it said itself the last time the app signed in.
          if (net.hub!.state.value == CarrierState.up)
            SettingRow(
              key: const ValueKey('relay-talks'),
              icon: icon(Lucide.network),
              label: relayTalksWords(net.hub!.relay).$1,
              hint: Text(relayTalksWords(net.hub!.relay).$2),
            ),
          // The relay asked for a pass phrase and none was given, or the one given was wrong (a relay hosted from someone's
          // app, lib/relay_host): asked for here, and the relay asked again with it.
          if (net.hub!.passRefused != null) SettingRowBox(child: RelayPassBox(net: net)),
          // A record of where this account lives that couldn't be made, said rather than swallowed (found in the
          // review of relays that talk, 2026-11-23): without one nobody on another relay can reach this account.
          if (net.homes?.problem != null)
            SettingRow(
              key: const ValueKey('relay-home-problem'),
              icon: icon(Lucide.triangleAlert),
              label: 'Friends on other relays can\'t reach you',
              hint: Text(net.homes!.problem!),
            ),
          if (!net.onDefaultHub)
            SettingRow(
              key: const ValueKey('relay-use-default'),
              icon: icon(Lucide.undo2),
              label: 'Go back to Uplink\'s relay',
              hint: const Tr('gogho.st, where everyone else is.'),
              onPress: () async {
                await net.useRelay('');
                if (context.mounted) toast(context, 'Using Uplink\'s relay again');
              },
            ),
          SettingRowBox(child: RelayAddressField(net: net)),
        ],
      ),
    // A relay of this device's own (lib/relay_host): on the Mac, Windows, Linux and Android.
    if (board != null) ...relayHostSections(context, net),
    PaneSection(
      title: 'Invite',
      footer: const Tr('Once they have the app and you text each other, it offers to turn encryption on between you. From then they are someone the routes reach.'),
      children: [
        SettingRow(
          icon: icon(Lucide.userPlus),
          label: 'Invite someone by text',
          hint: const Tr('Opens a new chat with an invitation written. Choose who, change the words if you like, and send it as any text.'),
          onPress: () {
            // In the app's frame a new chat opens in the pane, the invitation already in its message field.
            final shell = AppShell.maybeOf(context);
            if (shell != null) {
              shell.compose(body: inviteText);
            } else {
              push<void>(context, (_) => const ComposeScreen(body: inviteText));
            }
          },
        ),
      ],
    ),
    if (anyone)
      PaneSection(
        title: 'People you can reach',
        description: const Tr('Press one to send a test and see which route carries it.'),
        children: [
          for (final p in net.people)
            SettingRow(
              icon: icon(Lucide.userRound),
              label: peerLabel(p),
              hint: Text(board == null ? '' : 'By ${board.routes(p, metered: true).map((c) => c.name).join(', ').ifEmpty('no route now')}'),
              onPress: () => showChoices(context, title: 'Test the way to ${peerLabel(p)}', choices: [
                Choice('Send a test', Lucide.send, () => test(p)),
                if (board?.carrier('hub') != null) Choice('By the relay server only', Lucide.globe, () => test(p, only: 'hub')),
                if (board?.carrier('p2p') != null) Choice('By a direct link only', Lucide.link2, () => test(p, only: 'p2p')),
                if (board?.carrier('lan') != null && net.lanOn) Choice('By the local network only', Lucide.wifi, () => test(p, only: 'lan')),
                if (board?.carrier('sms') != null) Choice('By SMS only (one text on your plan)', Lucide.messageSquare, () => test(p, only: 'sms')),
              ]),
            ),
        ],
      ),
    // Which route each conversation is on: what the switchboard saw, this run and the week before it (GMFB-24).
    if (board != null && board.used.isNotEmpty) routesUsedSection(context, board.used, nameOf: _usedName, groups: Groups.instance.all),
    if (net.recent.isNotEmpty)
      PaneSection(
        title: 'Lately',
        children: [
          for (final e in net.recent.take(8))
            SettingRow(
              icon: icon(Lucide.clock),
              label: e.words,
              hint: Text('${e.via == null ? '' : '${board?.carrier(e.via!)?.name ?? e.via} · '}${_ago(e.at)}'),
            ),
        ],
      ),
    if (net.id != null)
      PaneSection(
        title: 'This phone',
        footer: const Tr('A name made from this phone\'s encryption key. A relay server and the other phones know this phone by it, and learn no number or name from it.'),
        children: [
          SettingRow(icon: icon(Lucide.keyRound), label: '${net.id!.substring(0, 8)} ${net.id!.substring(8, 16)}'),
        ],
      ),
  ];
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// A friend's name as Settings says it: their name or username as friends by username keep it, else as the routes know
/// them.
String _friendName(String id) {
  final b = Buddies.instance.byId(id);
  if (b != null) return b.shown;
  final p = Net.instance.byId(id);
  return p?.name ?? p?.address ?? '';
}

/// What a relay of one's own does and doesn't reach, in Settings › Routes (GMFB-25; docs/SELF_HOSTING.md). Since
/// relays talk to each other (docs/OPEN_NETWORK.md, section 4; Matt, 2026-11-22), friends cross relays; the rest is
/// still each relay's own.
const relayLimitsWords =
    'Relays can pass messages to each other. Add a friend on another relay as @name@their.relay, and what you write to each other goes through your relay to theirs, where both relays allow it. Everything else is still kept on each relay apart: usernames, your account backup, circles, spaces, calls, who is online and invite words reach only people using the same relay. Texts (SMS) still reach anyone. The Marketplace always comes from gogho.st. How to run one: gogho.st/docs/routes.';

/// What moving away from the relay at [from] cuts off, said before the move (found in the review, 2026-11-23): friends
/// who stay on it reach this account only where the two relays pass messages to each other.
String movingWords(String from) {
  final u = Uri.tryParse(from);
  final host = u == null || u.host.isEmpty ? 'the relay you use now' : u.host;
  return 'Friends who stay on $host reach you there only where it and the new relay pass messages to each other. Circles, spaces, calls and your account stay on the relay they were made on.';
}

/// Whether the relay in use passes messages to other relays, as a row's label and the line under it: by what the
/// relay said of itself in its hello ([relay]; null where it says nothing of itself, as a relay with that switched
/// off says nothing, and one from before relays talked).
(String, String) relayTalksWords(HubRelay? relay) => relay == null
    ? ('Doesn\'t pass messages to other relays', 'It has that switched off, or is from before relays talked to each other. You reach only people who use it.')
    : relay.fed
        ? ('Passes messages to other relays', 'A friend on another relay, added as @name@their.relay, is reached through this one.')
        : ('Doesn\'t pass messages to other relays', 'Whoever runs it hasn\'t switched that on. You reach only people who use this relay.');

/// The relay in use, in a line: as [relayInUseWords] names it, but one on a network that said it runs in someone's app
/// is not "your own".
String relayInUseLabel(Net net) {
  final words = relayInUseWords(net.hubUrl);
  final hub = net.hub;
  if (hub == null || !hub.hosted || !words.startsWith('Your own relay: ')) return words;
  return 'A relay in someone\'s app: ${words.substring('Your own relay: '.length)}';
}

/// How the relay's route stands, in a few words.
String _hubLine(Net net) {
  final hub = net.hub;
  if (hub == null) return 'not set up';
  if (net.board?.off.contains('hub') ?? false) return 'switched off above';
  return switch (hub.state.value) {
    CarrierState.up => 'connected',
    CarrierState.connecting => 'connecting…',
    CarrierState.down => hub.problem ?? 'not reachable now',
    CarrierState.off => 'connects when something needs it',
  };
}

/// Another relay's address, typed, checked and only then used (GMFB-25): an Uplink relay has to answer at it
/// ([Net.useRelay]), and the person is told what moving there means before anything changes.
class RelayAddressField extends StatefulWidget {
  const RelayAddressField({super.key, required this.net, this.connect});
  final Net net;

  /// A test's stand-in for dialling the relay.
  final HubDial? connect;

  @override
  State<RelayAddressField> createState() => _RelayAddressFieldState();
}

class _RelayAddressFieldState extends State<RelayAddressField> {
  late final _address = TextEditingController(text: _inUse);
  bool _checking = false;
  String? _problem;

  /// The address the field shows for the relay in use: empty for ours.
  String get _inUse => widget.net.onDefaultHub ? '' : widget.net.hubUrl;
  late String _shown = _inUse;

  @override
  void initState() {
    super.initState();
    widget.net.addListener(_moved);
  }

  /// The relay changed elsewhere (Go back to Uplink's relay): the field follows, unless something else was
  /// typed in it meanwhile.
  void _moved() {
    final now = _inUse;
    if (now == _shown) return;
    if (_address.text.trim() == _shown) _address.text = now;
    _shown = now;
  }

  @override
  void dispose() {
    widget.net.removeListener(_moved);
    _address.dispose();
    super.dispose();
  }

  /// Checks the address typed and moves to it ([Net.useRelay]), asking what moving there means once it has answered
  /// ([decideRelay]). A problem is shown under the field; declining changes nothing.
  Future<void> _use() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _problem = null;
    });
    final r = await widget.net.useRelay(_address.text, connect: widget.connect, decide: (url, check) => decideRelay(context, url, check));
    if (!mounted) return;
    setState(() {
      _checking = false;
      _problem = r.problem;
    });
    if (r.problem != null || r.declined) return;
    _address.text = _shown = _inUse;
    toast(context, widget.net.onDefaultHub ? 'Using Uplink\'s relay' : 'Using ${relayInUseWords(widget.net.hubUrl)}');
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      GlacierInput(
        key: const ValueKey('relay-address'),
        controller: _address,
        placeholder: 'relay.example.com'.t,
        ariaLabel: 'Another relay server\'s address',
        inputMode: TextInputType.url,
        size: GlacierFieldSize.md,
        onSubmitted: (_) => _use(),
      ),
      if (_problem != null)
        Padding(
          padding: EdgeInsets.only(top: t.space(2)),
          child: Text(_problem!, key: const ValueKey('relay-problem'), style: pageText(t, t.fontSize('sm'), color: t.color('app-danger'))),
        ),
      SizedBox(height: t.space(2)),
      SettingRow(
        key: const ValueKey('relay-check-and-use'),
        icon: _checking ? const GhostSpinner(size: 18) : const AppIcon(Lucide.check, size: 18),
        label: _checking ? 'Checking it answers…' : 'Check it and use it',
        hint: const Tr('Nothing changes unless an Uplink relay answers there.'),
        onPress: _checking ? null : _use,
      ),
    ]);
  }
}

/// A pass phrase for the relay in use, which asked for one (lib/relay_host): given, the relay is asked again with it.
class RelayPassBox extends StatefulWidget {
  const RelayPassBox({super.key, required this.net});
  final Net net;

  @override
  State<RelayPassBox> createState() => _RelayPassBoxState();
}

class _RelayPassBoxState extends State<RelayPassBox> {
  final _pass = TextEditingController();

  @override
  void dispose() {
    _pass.dispose();
    super.dispose();
  }

  Future<void> _try() async {
    final p = _pass.text.trim();
    if (p.isEmpty) return;
    await widget.net.setRelayPass(p);
    _pass.clear();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final wrong = widget.net.hub?.passRefused == 'wrong', busy = widget.net.hub?.passRefused == 'busy';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Text(
        busy ? 'Too many wrong pass phrases were given to this relay lately. It is asked again in a while.' : wrong ? 'The pass phrase given isn\'t this relay\'s.' : 'This relay asks for a pass phrase: whoever runs it can give it to you.',
        key: const ValueKey('relay-pass-why'),
        style: pageText(t, t.fontSize('sm'), color: t.color(wrong || busy ? 'app-danger' : 'app-ink-2')),
      ),
      SizedBox(height: t.space(2)),
      GlacierInput(key: const ValueKey('relay-pass-field'), controller: _pass, type: GlacierInputType.password, placeholder: 'Its pass phrase'.t, ariaLabel: 'The relay\'s pass phrase', autoCorrect: false, size: GlacierFieldSize.md, onSubmitted: (_) => _try()),
      SizedBox(height: t.space(2)),
      SettingRow(key: const ValueKey('relay-pass-try'), icon: const AppIcon(Lucide.keyRound, size: 18), label: 'Use this pass phrase', onPress: _try),
    ]);
  }
}
