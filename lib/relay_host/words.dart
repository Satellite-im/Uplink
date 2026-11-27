/// What the screens say of a relay hosted from the app (lib/ui/relay_host_section.dart, and the relay picker's "Use this
/// relay?" for one hosted by someone else): kept here, apart, so the tests read the same words the person does.
library;

import 'hosting.dart';

/// The switch, and the line under it while it is off.
const hostLabel = 'Host a relay on this device';
const hostOffHint = 'A relay of your own, the same one gogho.st runs, for you and whoever you let use it: devices on this network, and over Direct anyone you give its address to.';

/// What whoever runs a relay sees: said before it is switched on.
const hostSeesWords = 'Whoever runs a relay sees which installs connect to it and when, and who sends to whom. Never what is said: everything is sealed on each device before it leaves. Running this one, that is you.';

/// What someone joining a relay hosted from an app is told before they move to it, and while they are on it.
const joinHostedWords = 'This relay runs in someone\'s Uplink app. They see which installs connect to it and when, and who sends to whom, never what is said. It is up only while their app is open. $keepsNoAccountsWords $closedPhoneWords';

/// What a relay hosted from an app doesn't keep, and so what doesn't work while on it.
const keepsNoAccountsWords = 'It keeps no accounts, usernames or invite words: while you are on it, adding a device, refreshing your backup, deleting your account and finding friends by username don\'t work.';

/// What an Android phone can't do on a relay hosted from an app.
const closedPhoneWords = 'On an Android phone, a closed app can\'t check it for new messages: they come when you open the app.';

/// Said where a relay hosted from an app can't be moved to yet, its link to its public relay not standing.
const hostedNotLinkedWords = 'It can\'t be used yet: until its public relay lets it stay linked, friends on other relays couldn\'t reach you there, nor you them.';

/// How long it runs, on a phone or a computer.
String hostRunsWords({required bool phone}) =>
    '${phone ? 'It runs while you use the app on this phone, and stops a minute after you put the app away.' : 'It runs for as long as Uplink is open on this computer.'} $whenItStopsWords';

/// What the people on it see when it stops, and what waits.
const whenItStopsWords = 'When it stops, everyone on it sees their relay as unreachable, and their app tries it again by itself until it is back. What they write to friends waits in their app and goes again, for up to three days; what the relay was keeping for them in memory goes with it.';

/// The relay it stays linked to, chosen.
const viaChoiceWords = 'Its people are reached through the relay it stays linked to: Uplink\'s own unless you choose another, which must let relays hosted from an app stay.';

/// What this computer's firewall will ask as the relay first listens, said before it does ([os]: PlatformInfo's
/// operatingSystem). Nothing on a phone.
String firewallWords(String os, int port) => switch (os) {
      'macos' => 'macOS may ask whether Uplink may accept incoming connections: choose Allow, or devices on this network can\'t reach it.',
      'windows' => 'Windows will ask whether Uplink may communicate on your networks: allow private networks, or devices on this network can\'t reach it.',
      'linux' => 'If this computer has a firewall, it must let port $port in for devices on this network to reach it.',
      _ => '',
    };

/// What a local network sees of a relay on it.
const lanSeenWords = 'On this network, who signs in to it and who talks to whom can be seen by others on the network. What is said is still sealed end to end. It takes 3 connections at a time from one device on the network, and 64 in all.';

/// Its limits, in memory.
const hostLimitsWords = 'It holds up to 200 connections at once, and keeps up to 32 MB in memory for people who are away: 24 MB of what is sent to them, 8 MB of what rooms keep.';

/// What its folder keeps, said when it is switched off and under the section.
const keptWords = 'Its folder keeps its key (so it keeps its name, and its people find it again), where its people said they live, and which of them sign in the newer way. Nothing anyone said: that was only in memory.';

/// Said where signing out is asked, while this device hosts a relay: where everything here can be deleted too
/// ([everything]), its folder goes with it.
String signOutHostWords({required bool everything}) =>
    'It also stops the relay on this device and switches it off, and forgets its pass phrase: everyone on it sees their relay gone. Its folder (its key, where its people said they live) stays${everything ? ', unless you delete everything here' : ''}.';

/// What moving this app onto its own relay means for the account's other devices and its friends, through [viaHost]
/// (offered only while [viaHost] lets it stay linked, and never on a phone).
String moveHereWords(String viaHost) =>
    'Your other devices stay on the relay they use until you move them too: until then they don\'t get what you send from here, nor this device what friends send them there. Friends are told you moved, and reach you here through $viaHost. Until a friend\'s app has heard, what they send waits on their relay: about 200 messages at most, for up to three days, and lost if that relay restarts. If the link to $viaHost drops, what you send to friends elsewhere doesn\'t reach them until it is back. People on this relay, on this network or over Direct, reach you at once. $keepsNoAccountsWords';

/// Said in "Use it for this app"'s place on a phone.
const phoneNotHereWords = 'Not on a phone: it stops a minute after the app is put away, and a closed app can\'t check it for messages. Use it from a computer, where it runs while the app is open.';

/// The pass phrase, set or not.
const noPassWords = 'No pass phrase: anyone who has its address can use it.';
const passWords = 'People must give the pass phrase to use it. On a shared network a short one can be guessed from what is overheard: make it long. Wrong guesses make the guesser wait, but someone guessing from many places can keep people new to it out for an hour at a time; those who have used it, and you, are never kept out.';

/// Reaching it over Direct.
const directOnHint = 'They need Direct on too. Nothing is opened on this device for it, and it works from anywhere.';
const directOffWords = 'Switch Direct on above, and anyone you give this address to can use it from anywhere, with Direct on at their end too.';
const directNoHelperWords = 'No link helper is known yet, which devices far away find it through: one is named by the relay this app signs in to. Until then, devices on this network reach it.';
const directNoneWords = 'Reaching it from anywhere, over Direct, comes with Direct, which this build doesn\'t have yet.';

/// How it stands, in a line.
String hostStateWords(RelayHosting h) => switch (h.state) {
      HostState.off => h.on ? 'Stopped while the app is put away: it starts again when you come back' : 'Off',
      HostState.starting => 'Starting…',
      HostState.up => '${h.connections == 1 ? '1 install connected' : '${h.connections} installs connected'}, of 200',
      HostState.failed => h.problem ?? 'It couldn\'t start',
    };

/// How its link to the public relay at [via] stands.
String viaWords(ViaLink link, String via) {
  final host = Uri.tryParse(via)?.host ?? via;
  return switch (link.kind) {
    ViaKind.off => 'It stays linked to $host while it runs, so friends on other relays can reach its people.',
    ViaKind.linking => 'Linking to $host…',
    ViaKind.stays => 'Linked to $host: friends on other relays reach the people on yours through it.',
    ViaKind.linkedOnly => 'Linked to $host, which doesn\'t let relays hosted from an app stay: friends on other relays can\'t reach the people on yours yet.',
    ViaKind.refused => '$host doesn\'t take links from other relays yet${link.said == null || link.said!.isEmpty ? '' : ' (it says "${link.said}")'}. Until it does, the people on your relay reach only each other. It is asked again by itself.',
    ViaKind.down => '$host can\'t be reached just now. It is tried again by itself.',
  };
}

/// Asked before a relay's link is followed: the address it carries, and that checking it connects there.
String checkFirstWords(String url) => 'A link asks this app to use the relay at $url. To see what it is, the app connects to it. Nothing changes until you say yes after that.';
