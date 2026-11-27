# The open network: direct links, relays that talk, a relay in the app, the web client

Matt, 2026-11-22: "do a major overhaul to make our network support p2p delivery with the relay as a primary source
but have p2p as a secondary back up that validates everything our relay says (maybe a bit slower so we use the relay
for speed, p2p for verification) I'd like the relays to be able to talk to each other and i'd like everyone to be
able to host a relay from their client, also build the full web client while we do this ... look at iroh as the rust
backend for the p2p side and take signficant inspiration from uplink".

This is the plan the work follows, and the reference for what is built. `docs/network.md` says what a route is;
this says what is added on top of it. Each part is behind its own switch and lands on its own, so the app is
releasable at every step. **Status** lines say what is built; everything else is the plan.

| Part | Where | Status (2026-11-23) |
| --- | --- | --- |
| Seams: a hub link and a hub socket that are not a WebSocket | `lib/net/hub_link.dart`, `relay/lib/hub.dart` | built, in 0.12.13 |
| A link helper (iroh's relay server) for direct links | `tool/build-link.sh`, `tool/deploy-link.mjs`, `native/link-check/` | live at `https://gogho.st:7843` (UDP 7842 for address discovery); not yet handed out by gogho.st's relay (`GHOST_LINK_HELPERS` is set when Direct ships) |
| The direct network's core (Rust, iroh 1.5) | `native/p2p/`, `lib/net/p2p/node_ffi*.dart` | built, reviewed, fixed; carried by the Android, Mac, Windows and Linux builds and never opened until Direct is switched on; run end to end between the Android emulator and a Mac through our link helper |
| The direct route (`p2p`) | `lib/net/p2p/` | built, reviewed twice, fixed; offered in Settings › Routes on Android, the Mac, Windows and Linux, off until the person switches it on (`net_direct`; the default later). The contract it holds the core to is `lib/net/p2p/node.dart`. Next, a review of the core and the route together |
| Checking the relay: the ledger, the name watch | `lib/net/ledger.dart`, `lib/net/name_watch.dart` | the name watch in 0.12.16; the ledger built, reviewed and fixed, running while Direct is on (it compares over direct links) |
| Relays that talk to each other | `relay/lib/federation.dart` | built, reviewed four times, fixed (relay and app); merged; gogho.st's relay runs it switched off (`GHOST_FED` unset, deployed 2026-11-23); the app's side in 0.12.17. It is switched on once the v2 sign-in (0.12.17, the browser extension's 0.2.2) is in enough apps: `GHOST_HUB_NAMES` first, then `GHOST_FED=open` |
| A relay hosted from the app | `lib/relay_host/`, its options in `relay/lib/hub.dart` and `federation.dart` | built on `relay-host`, reviewed twice and fixed; off by default, not merged yet. Usable for an app only once its public relay lets it stay, which gogho.st doesn't yet (section 5) |
| The web client | `lib/web/`, `web/` | runs end to end in Chromium and WebKit (text, friends, circles' chat; no calls yet); merged after four reviews, its changes to phones and computers in 0.12.17 (part 6 says what it keeps and where it is served); not on `app.gogho.st` yet: its block and build are ready, its DNS record is to add |

Each part is reviewed independently before it is switched on, and every review finding is fixed with a test that fails
without its fix. The reviews also found things wrong in what was already live, now fixed: a compressed message could
stop the relay (0.12.13's relay deploy), a friend by username's message could be handed to texting on Android
(0.12.14), who sent something was decided by an address a group's admin writes (0.12.15), and an app's sign-in to
the relay named nothing of the relay it was made for, so another relay could sign in with it (the v2 sign-in, in
0.12.17 and the relay, used once gogho.st lists its names).

## What stays true

- **The relay comes first.** It is the fast path and the one that keeps things for someone who is away. The direct
  route comes after it: a way through when the relay can't carry something, and the way the relay is checked.
- **Everything is sealed before a route sees it** (`lib/net/switchboard.dart`, forward secrecy included). The direct
  route, a relay passing a packet to another relay, and a relay someone hosts all carry the same sealed packets.
- **Nobody is found by strangers.** A device makes direct links only with its own account's devices and with
  friends, and tells only them where it is. Nothing is published to a public directory.
- **Old builds keep working.** Every new thing said is a new envelope kind, a new field a build from before passes
  over, or a new message a relay from before answers "no such thing" to.
- **Rust carries bytes and nothing else.** Every rule below is Dart, so the tests, the phone, the computer and the
  browser share one implementation.

## What we take from Uplink

Uplink (Satellite.im) is built on Warp: identity, messaging, files and calls as interfaces over a peer-to-peer
network, with "shuttle" nodes anyone can run that keep things for people who are away. What this takes:

- **Who you are is a key, not an account on a server.** Already so here (an install's name is made from its key).
  New: a signed record of where you live (**home record**), so you can be found on any relay and can move.
- **Servers are helpers anyone can run**, and they talk to each other: relays that pass packets on, and a relay
  hosted from the app.
- **Devices talk straight to each other** where they can. Here that is a second route and a check, not the only way:
  Uplink's weak point is delivery when a straight path can't be made, and the relay is what covers that.
- **The same core in the browser.** The web client runs the same Dart.

## 1. Who is who

Unchanged: an account is a P-256 key pair; its **name** is the first 16 bytes of the SHA-256 of the public key, in
hex. Every device of the account holds the key. Each install has a **device** name (`hub_device`, 32 hex).

New, per device:

- A **node key**: 32 random bytes made on the device, kept in the secret store (`p2p_node`), never in the account's
  backup. The direct network's core turns it into the device's **node id** (an Ed25519 public key, 64 hex).
- A **device card**, which says "this node id is a device of this account":

      {"v":1, "a": account name, "k": account public key (33 bytes, base64), "d": device, "n": node id,
       "t": made (ms), "x": good until (ms), "s": signature (r then s, base64)}

  signed by the account's key over `"ghost-p2p card v1\n"` then `a (16) | d (16) | n (32) | t (8) | x (8)`.
  Anyone can check it: `idOf(k) == a`, and the signature is `k`'s. Good for 30 days, made again when a week is left
  or the node id changes.

New, per account:

- A **home record**, which says where the account lives:

      {"v":1, "a": account name, "k": public key, "h": [up to 3 relay addresses], "n": a count that only goes up,
       "t": made (ms), "s": signature}

  signed over `"ghost-home v1\n"` then `a | n (4) | t (8) | how many | each address, length first`. The highest `n`
  wins. Moving to another relay is signing a record with the next `n`.

A relay address is `wss://host/hub`, or for a relay hosted from an app `ghost-relay://<relay name>?n=<node
id>&via=<a public relay it stays linked to>` (section 5).

## 2. The direct route

**The core** (`native/p2p/`, Rust on iroh 1.x): a node started with the node key. It offers one thing: framed
streams to another node by its id, on a numbered channel. It dials, punches through NATs, falls back to a **link
helper** (iroh's relay servers: they help two devices find each other and carry their sealed traffic when a
straight path can't be made; they are not our relay), and says how each path stands (straight, through a helper,
gone). It turns away any node the app has not allowed, as soon as the handshake says who it is.

    channel 0  packets (this route)
    channel 1  a hub connection to a relay hosted from an app (section 5)
    channel 2  a relay talking to a relay (section 4)

How it is set up, and why (researched 2026-11-22, iroh 1.5.0):

- **Nothing public.** The endpoint is made with no address lookup at all (`presets::Minimal`): no DNS or pkarr
  record, no DHT, no mDNS. Where a device is, only its friends' devices and its own account's hear, in sealed
  envelopes (below), and that is what a dial is given.
- **Link helpers are ours, handed out by the relay.** iroh's public ones are for "development and hobby use only",
  so the app ships with none of its own: the relay's hub says which to use as an app signs in (`"helpers"`, from
  `GHOST_LINK_HELPERS`), as it hands out the call relay. Ours is an `iroh-relay` on the box (`tool/deploy-link.mjs`,
  on Matt's word). With none, links are made only between devices that can reach each other's addresses as they
  are (one network).
- **A phone's node is up only while there is something to say.** A node keeps every path warm every 5 seconds and
  its link helper every 15: megabytes a day and a radio that never sleeps (iroh issues 4651, 4590). A computer's
  stays up; a phone's is started for a send that fell back or a check, and stopped two minutes after its last
  stream closes.
- **Dart talks to it through a small C interface** (`native/p2p/src/ffi.rs`, `lib/net/p2p/node_ffi.dart`), not a
  generator: commands in as bytes, events out as messages to the isolate's port (never a call into Dart, so an
  isolate that has gone cannot be called; its nodes go with it). Nothing of the core runs before a node is first
  started: on Android that is when Kotlin loads it and gives iroh's DNS the app's context
  (`install_android_jni_context`), so a person who never switches Direct on runs none of it.

Dart reaches it through `lib/net/p2p/node.dart` (`P2pNode`): the real one over FFI, a stand-in mesh for tests
(`test/support/fake_p2p.dart`), and in the browser none (the core as WASM reaches others only through a link
helper; later). Where the library is not in a build, the route is simply not there.

**Switching it on.** Direct is offered where the app's builds carry the core (Android, the Mac, Windows, Linux:
`Net.p2pNode`, set where the app starts; not an iPhone, whose build carries none yet, nor a browser), and it starts
off: it is the one route whose choice is its own (`net_direct`, 'on' or 'off', nothing where never chosen), not in
`net_off`, so that the day it becomes the default (`Net.directByDefault`) reaches those who never chose and not those
who switched it off. Until it is on, nothing of it is made: the core's library is not opened, no node key is made,
nobody is asked who is a friend, no ledger is kept, and a card a friend sends is nobody's to take. Switching it on
(Settings › Routes) makes the node, the route and the ledger without the app starting again, and gives the node the
link helpers the relay already named; switching it off closes every link, stops the node (kept, stopped, for the next
time), lets nobody it let in stay let in, and takes the route and the ledger out. The ledger says it stopped listening
(`Ledger.pause`), and the next one compares only what came after it began. Before it is on, Settings › Routes says
what switching it on means (below), lets "Only through link helpers" be chosen first, and where the relay in use names
no link helper, says that devices behind most home routers can't link.

**Telling each other where we are.** A new envelope kind, `p2p`, never asked to be answered, never sent by a route
that carries only small packets:

    {"t":"card", "c": device card, "w": {"r": link helper address, "a": [addresses], "t": ms}}
    {"t":"card?"}                    tell me yours
    {"t":"meet", "c": …, "w": …}     I am up, here: bring your node up and link, and tell me where you are

A device sends its card to a friend when they become friends, when its card changes, and when asked; its
whereabouts with it, and again with a `meet`. To the account's own devices the same goes through the account's own
name (`Net.mine`). What is kept: for each friend, up to 8 devices' cards and whereabouts (`p2p_cards`), dropped when
the card runs out or the friend is removed or blocked. A `meet` is answered at most six times an hour for one
friend, and not at all while Direct is off or the person chose Invisible.

**The route** (`P2pCarrier`, id `p2p`, shown as "Direct"):

- `reaches(peer)`: Direct is on, this build has the core, and an unexpired card is held for one of their devices.
- `send`: the node is started where it was not (a phone's), and the packet goes to every device a card is held
  for, on channel 0, dialling where no stream is open by where each last said it was (5 s in all). Passed if one
  took it; otherwise it throws and the switchboard goes on. It never keeps anything.
- What arrives is vouched for: the stream's node id has a card, and the card's account is who it is from
  (`Arrived.from`), as the hub's stamp is.
- A stream is let go after 90 s with nothing said. Nothing is dialled while the person chose Invisible, except to
  their own devices.
- **Meeting.** A device that wants a link with one whose node may be down (a check is due; something only kept by
  the relay) starts its own and sends a `meet` through the relay; the other brings its node up, answers with where
  it is, and the two dial. With the relay itself gone there is nothing to ask through: each device that sees the
  relay down for 15 s brings its node up by itself, and dials by what it last heard.

**The switchboard**: the order becomes `hub`, `p2p`, `lan`, `sms`. Two changes:

- When the hub only kept something (they are not connected to it) and a direct stream to one of their devices is
  open, it goes by that too, without waiting.
- It tells the ledger what was sent, by which route and what the route said, what came, and what was answered.

**Who learns what.** A friend's device learns this device's network address, as with any direct link; nobody else
does. A link helper sees node ids, addresses and how much is sent, never an account's name or what is said.
Settings › Routes has the switches: Direct on or off, and "Only through link helpers" (a friend's device then
sees the helper's address, not this one's).

## 3. Checking the relay

What the relay says, and what checks it:

| The relay says | Checked by |
| --- | --- |
| "Passed on" / "kept for them" | the other end's own answer (sealed), and the **ledger** compared over a direct link |
| "This is everything kept for you" | the ledger: what friends' devices say they sent |
| "They are here / away / gone" | a direct link being up, and what the friend's device says of its own connection |
| "@name is this key" | the **name watch**: friends' devices asking the same question and comparing |
| Who is in a room, what a room kept | not yet: later, members' own word over direct links |

**The ledger** (`lib/net/ledger.dart`). For each friend (and, later, the account's own devices), two short lists
kept for 7 days, at most 500 each: what was **sent** them (envelope name, when, the route, what the route said:
passed or kept, whether it was answered) and what was **got** from them (name, when, the route). Only what asks for
an answer is listed (not typing, tests, cards or the ledger's own messages). Kept with the app's choices; no words
of any message are in it.

When a direct stream to a friend's device opens, and every 15 minutes while it stays open, the two compare
(envelope kind `ldg`, by the direct route only):

    {"t":"sum", "w":[from, to], "s": names sent to you, "g": names got from you,
     "h": {"u": my relay, "up": whether I'm connected to it, "t": since when}}
    {"t":"dif", "want": names}                       I never got these: send them straight
    {"t":"was", "e": [[name, when, "p" or "k"], …]}  what the relay told me of each when I sent it

- What they sent that never came here is asked for (`want`) and sent again straight, by whoever still holds it
  (Friends' own list of what is unanswered, `lib/friends/friends.dart`; a call that has stopped ringing is not).
- What came here but they never heard was answered is marked answered: the answer was what got lost.
- Each thing that had to come straight is put down as one of: **made up for** (this device was away and another of
  the account's took it, or it could not be opened here), **the relay said passed, and it never came** (this
  device was connected to the relay at that moment), or **the relay kept it and never handed it over** (this is the
  account's only device, it signed in after, and the packet was not among what was handed over).
- A friend whose device says it is connected to the same relay while the relay says they are gone is put down as
  the relay being wrong about who is here.

Settings › Routes shows it per relay: when it was last checked and with how many devices, how many messages
matched, how many were made up for, and each thing the relay got wrong with its day. "Check now" dials the friends
the relay says are here (once a minute at most). With no direct link in use, a round runs by itself while the app
is on screen: up to 5 friends not compared in a day, every hour on a computer and every 6 hours on a phone.

**The name watch** (`lib/net/name_watch.dart`). A friend added by username was found by asking the relay "who is
@name". Each friend's app asks the same again once a day, and of its own name each time it signs in. An answer
that is a different key is shown on that friend ("The relay now says @maya is a different key; you are still
talking to the Maya you added"), and the friend is told by every route, so their app can say "a friend's app saw
the relay give your username to another key". An add-me link carries the first 8 hex digits of the key after `#`
(never sent to a server), and the app refuses an answer that doesn't match.

**What this does not check:** rooms (circles, spaces, voice), what the relay says to the browser client (it has no
direct route yet), and anything while no two devices are ever online together.

**What a restart loses** (GMFB-24). The hub holds what is kept for someone away, and what a room keeps, in memory;
a restart loses it, and the `since` it says with each sign-in lets the ledger put that down to the restart, not to
the relay. A relay whose keeper sets `GHOST_HUB_KEEP_HELD=1` keeps both on its disk too (`relay/lib/held_store.dart`):
the sealed packets, and **who each is for, who sent it and when**, for up to seven days, so a stop loses nothing and
a crash its last fifth of a second, and after a clean stop `since` stays the start of the hub before. It is off on
our relay until Matt switches it on: it puts a week of who-wrote-to-whom on the box's disk (`relay/README.md`, "What
it keeps"). A relay hosted from the app never keeps it.

## 4. Relays that talk to each other

A relay gets a key of its own (`relay-key.json`), and a name made from it as an install's is. Its hello to an app
says so (`"relay": {"id", "key"}`), which a build from before passes over.

**A link between two relays** is one relay dialling the other's hub address and saying, in place of an app's
hello, who it is, its own hub address where it has one, and a number it made up; the other answers with its own
key. As built, each signs `"ghost-fed v2 "`, the number, both names and the address dialled, so a hello can't be
used at another relay or another address; `relay/README.md` (Other relays) has every field, the allowances, and the
standing links a relay keeps up. Each proves it holds its key; one that names a `url` is believed once the other has
dialled that address and seen the same key there (TLS says whose address it is). A relay with no address of its own
(one hosted from an app, section 5) links outward only. Whether a relay links at all is its keeper's choice:
`GHOST_FED=off | open | list`, with `GHOST_FED_ALLOW` and `GHOST_FED_BLOCK`. Off by default, and off on gogho.st
until the v2 sign-in is in enough apps.

**What crosses a link:**

    [5][number: 4][to: 16][from: 16][packet]      → {"ack": number, "here": bool} or {"nak": number, "err"}
    [6][number: 4][to: 16][from: 16][relay: 16][packet]   the same, for a relay linked to the one asked (section 5)
    {"fed":"home", "rec": home record}
    {"fed":"whois", "q": n, "name"} → {"fed":"whois", "q": n, "id", "key", "home"} or {"none": true}

- A relay learns where someone lives only from their **home record**, which it checks; never from anyone's say-so.
  An app gives its relay its own record as it signs in (`{"dir":"home"}`) and its friends' as it needs them.
  Friends hear each other's records from each other, sealed: an envelope of kind `home` (`{"rec": …}`), sent when
  two become friends and whenever the record changes.
- A packet for someone not connected here whose record names another relay is passed to that relay, which hands it
  to their devices or keeps it as it would its own. One hop, or two through `via`; never further.
- **A relay speaks only for its own people:** what relay A passes on as from X is taken only where X's record
  names A as home. So a relay can't put anyone else's name on a packet.
- With the other relay down, packets wait here (per relay: 2,000 packets or 16 MB, seven days), and the sender is
  told "kept".
- Limits per linked relay: packets a minute, bytes a day, and the same mailbox limits per person as ever.

**Names.** `@maya` is a name on the relay you are on; `@maya@relay.example` is one on another. The app asks its own
relay (`{"dir":"whois","name":"maya","at":"relay.example"}`), which asks the other over a link; where its own relay
doesn't link, the app asks the other relay itself. The friend is kept with their home record, and every packet to
them goes through the app's own relay as now.

**Moving.** Signing a home record with the next count, giving it to the old relay, the new one and one's friends.
Friends' apps follow the record; the old relay passes on what still comes to it.

**Not in the first version:** who is here across relays (the direct link says it instead), and rooms across relays
(a circle stays on the relay it was made on; the app joining a room on another relay is the step after).

## 5. A relay hosted from the app

Matt, 2026-11-22: "i'd like everyone to be able to host a relay from their client". **Built** on `relay-host`
(`lib/relay_host/`; the relay's options in `relay/lib/hub.dart` and `federation.dart`, each inert unless set, so
gogho.st's relay, whose `bin/relay.dart` sets none, says and does what it did), off by default, on the Mac, Windows,
Linux and Android. An iPhone and a browser have none (`lib/relay_host/relay_host.dart` chooses the half; a browser's
build never names the relay package, which the guard test holds it to). Settings › Routes › Host a relay on this device
runs the same hub gogho.st runs, in the app:

- **A key and a folder of its own**: `relay/` under the folder this copy of the app keeps everything in (beside a
  computer's store; Android's files): `relay-key.json` (its name to everyone), `homes.json` (where its people said they
  live), `hub-v2.json`, `hub-pass.json` (which installs have given its pass phrase). Nothing anyone said is written.
- **Small limits**, the hub's own settings: 200 connections; 32 MB kept for people who are away (24 MB held for them,
  counted with what holding each costs, and 8 MB of what rooms keep); 16 MB in flight, 4 MB waiting for one connection;
  8 MB waiting for its public relay; 2,000 v2 keys (200 new an hour) and 1,000 home records of each kind. No usernames,
  accounts, invite words, pushes or call relay of its own: while on it, adding a device, refreshing the backup,
  deleting the account and finding friends by username don't work, and the screens say so.
- **A pass phrase**, where the person sets one (`Hub(pass:)`): proved for each connection and each install
  (PBKDF2-HMAC-SHA256, 20,000 rounds, salted with the relay's own name, which its hello says, then HMAC over the hub's
  number and the install's name), never sent. Wrong ones cost whoever gives them: each place (an address on the
  network; over Direct the node) has five free, then waits a minute, doubled each time, an hour at most; strangers
  together have 200 an hour, past which only installs that never gave the phrase there wait. Those who have given it,
  and the host's own app in memory, are never shut out by a stranger. An app refused waits for a phrase, or as long as
  the relay says, instead of trying again.
- **Reached three ways:** this app in memory (a HubLink straight to a HubSocket); devices on the same network at
  `ws://address:port/hub` (port 7787 unless changed; only at private addresses of a network of the device's own, never
  a phone's mobile data), behind a door that takes 8 connections from one address (3 of them signed in) and 64 in all and closes a request not
  finished in five seconds; and from anywhere over Direct, a hub connection on channel 1 to its node, Direct on at both
  ends, by `ghost-relay://<relay name>?n=<node id>&via=<public relay>`, which the relay picker takes and holds to that
  relay: its hello carries the relay key's signature over the connection's number and the node dialled, so another
  relay, or a node copying this one's public card, is refused. A sign-in to it is bound (v2) to the node dialled over Direct, to its name
  in memory, or to the address on the network.
- **Its link** (`ghostmsg://relay?a=…`, as its QR code holds and the share sends): opens the app at "Check this
  relay?", and only on a yes is the address dialled, then "Use this relay?". A link names only a hosted relay or a
  `ws://` relay on a local network; any other relay is taken only typed in (on Android a relay that says it doesn't know
  the account makes the app forget the account's words and keys).
- **Linked to a public relay** (`via`, gogho.st): as a relay with no address, it dials out and asks to stay; its
  people's records say `ghost-relay://<its name>?via=…`, and others reach them through the public relay (`[6]`). The
  public relay says whether it may stay (`"stay": true`), and Settings shows how the link stands, as it answered. Its
  hello says it talks to other relays (`fed`) only while it stays. gogho.st has federation off and answers "not a relay
  that talks to others"; until it takes the link, the people on a hosted relay reach only each other, so neither "Use
  it for this app" nor a joiner's "Use this relay" is offered.
- **Up while the app runs:** on a computer while it is open; on Android stopped a minute after the app is paused or
  hidden (not merely inactive: split screen, the shade), and started again as it comes back. On a phone it is never
  offered for the app itself, and a closed Android app can't check a hosted relay for messages (its check needs ws or
  wss and sends no pass phrase). Stopping closes every connection: the apps on it see their relay unreachable and dial
  again by themselves, and what it kept in memory goes. Switched off, it first moves this app back to the relay it used
  before. Signing out stops it, switches it off and forgets its pass phrase; its folder stays. The routes don't wait for
  it to start.
- **What the host sees:** which installs connect and when, and who sends to whom; never what. Said before it is switched
  on, and to whoever joins (its hello says `"hosted": true`); a joiner at a network address is told what the network
  sees too.
- **This app on it:** "Use it for this app" is GMFB-25's relay switch, with its home-record move. The account's other
  devices stay on their relay until moved; friends are told, and reach it through the public relay. Until a friend's
  app has heard, what they send waits on their relay (about 200 messages, up to three days, lost if it restarts).

Not yet: gogho.st taking the link (`GHOST_FED` and `GHOST_FED_STANDING` there, after the v2 sign-in); Direct switched on
in a build; a relay on an iPhone; the pass phrase put in Unicode's one form (NFC) before it is proved (trimmed only).

## 6. The web client

The same app, built for the browser, as one more device of an account: sign in with the username and password,
which fetches the account's sealed backup as any new device does (`lib/account/account.dart`). A browser is the
**standalone** mode a computer with no phone linked already runs in (`lib/standalone/`).

What stood in the way, surveyed 2026-11-22, and what answers each:

| In the way | Answer |
| --- | --- |
| The import graph is one piece (`net.dart` reaches 355 of 377 files), so nothing can be left out by not importing it | One build of the whole app (dart2js), with its own entry, `lib/web/main.dart` |
| `dart:ffi` in two files (TDLib, Apple's SHA): a compile error | Split by conditional import; the browser's half says "not here" |
| `fast_gcm.dart` needs 64-bit integers | A browser half that uses the browser's own AES-GCM, or 32-bit halves |
| `Platform.isX` 166 times in 59 files: compiles, then throws in a browser | `lib/platform_info.dart`: the same questions, answered from `dart:io` where there is one and "a browser" where not |
| `Isolate.run` in 14 files | `runAside()`: an isolate where there is one, in place where not |
| `gzip` from `dart:io` on the sign-in path | A Dart one (`package:archive`) in the browser |
| Argon2id (64 MiB, 3 passes) would freeze the page | The same JavaScript one the extension uses (`extension/src/ghost/crypto.ts`), which gives way as it works |
| The platform seam (`SmsCalls`: about 40 calls) | `WebCalls`, beside `StandaloneCalls`: `UsernameChats` as it is, kept in IndexedDB as one record |
| The Keychain | Every record in IndexedDB sealed with a key the page can use but not read out (WebCrypto, not extractable); the recovery words and the password's key not kept at all, and the password asked again whenever they are wanted (below: what a browser keeps) |
| The hub's WebSocket | `hub_link_web.dart` (the seam) |
| Pickers that hand back paths | Bytes in the browser |

In the first version: signing in, friends and groups of friends, circles and their spaces' chat, calls (the
browser's WebRTC, as `site/join/voice.js` already proves the room protocol in one), who is here, profiles,
reporting, formatting, forward secrecy. Not in it: texts through a phone, the other networks' chats (they need
helper programs), Files spaces unless the build has them (below), files in a space's chat, plugins and the Marketplace, recording, the voice changer and noise removal, screen
sharing, the local API, and the direct route (so the browser doesn't check the relay). A closed tab gets nothing:
there is no push to a browser yet.

Tried against a relay on this machine (`dart run relay/bin/relay.dart`), with accounts made for the test
(`tool/web/e2e.mjs`, in Chromium and WebKit).

**Calls** (GMFB-30, GMFB-51) are the app's own call code (`lib/voice/`: the room protocol, its sealing, the TURN relay
the hub hands out) on the browser's WebRTC: flutter_webrtc has a browser half, so `RtcMedia` runs there as it is. What
differs is small: a browser plays a received sound only through a media element of the page's, so
`lib/voice/call_sound.dart` puts each person's sound in an audio element (at their volume, up to as loud as they
arrive; silenced as muting and deafening say; through the speaker chosen where the browser lets a page choose one,
which Safari doesn't). Settings › Voice and video there has the microphone, the browser's own noise suppression, the
sound's bit rate, stereo, echo cancellation and automatic gain, and the camera's quality, and says what a browser's call leaves out: recording, the voice changer, noise
removal beyond the browser's own (RNNoise, DeepFilterNet), boosting past 100% and screen sharing, all of which need the
app's native halves. In every build since 2026-11-25 unless left out (`node tool/build-web.mjs --no-calls`,
`Sms.browserCalls`; before, only with `--calls`). Tried by `tool/web/e2e.mjs`: two
browsers ring each other and hear each other (WebRTC's own count of the sound's bytes and energy received, and the
element playing it), muted is silence, both join a circle's voice space and hear each other, a camera's picture is
decoded on the other side, and someone muted for one person alone is not played there. A browser remembers a
microphone or camera allowed for a whole address, not for a page: at gogho.st/app the grant belongs to all of gogho.st
(its other pages included, `/join` among them, a guest's way into a call), while app.gogho.st's is its own; one
more reason the app has an address of its own.

**Files spaces** (GMFB-30's last box) are the app's own files layer (`lib/files/`) with the few places it touches the
device split off, as the rest of the web client was. What a browser does differently is only where bytes come from and
go to; every rule stays in one place for both: the sealing and its chunks (`lib/net/file_seal.dart`), the relay's
files routes, their signing and their errors (`FilesApi`), and the log, the roster, the queue and the rules of who may
do what (`FilesStore`). The split, smallest first:

| The app has | A browser has instead |
| --- | --- |
| dart:io's `HttpClient` under `FilesApi` | The page's own `fetch`, its answer read as it streams (`lib/files/files_http.dart`: a pair, with the request built and its answer read in plain Dart, `files_http_fetch.dart`, so a test drives it with a stand-in fetch) |
| A file's path, read a piece at a time and hashed on another isolate (`FileSource`, `lib/files/file_source.dart`) | The picked or dropped `File`, read a piece at a time with `Blob.slice` and hashed a megabyte at a time between frames |
| AES-GCM in Dart on isolates (`FastGcm`) | The browser's own AES-GCM (WebCrypto), chunk by chunk, with `FileSeal`'s own nonces and bindings (`lib/net/file_seal_async.dart`); the Dart one in a browser is a megabyte or two a second and holds the page still |
| The part file and the cache folder | What comes down goes into a `Blob` a chunk at a time (`lib/files/file_sink.dart`), checked against its SHA-256 as it comes, then saved with the browser's own download or shown in the page (pictures, videos and sounds where the app shows them) |
| The lists, the queue and the cache kept on disk | Nothing kept: a space's list is read from the relay each time the page opens it, an upload stops with the tab (the relay lets its part go a day later, or Remove does), and what came down lasts until the tab closes |

In every build since 2026-11-25 unless left out (`node tool/build-web.mjs --no-files`,
`--dart-define=GHOST_WEB_FILES=false`, `Sms.browserFiles`; before, only with `--files`). Nothing is opened in a tab of its own: a file someone put in a space could be a page with a
script in it, and at the app's address it could read the store. So a browser shows pictures, videos and sounds in
the app's own page (Flutter draws a picture; the `<video>` element plays the others) and saves everything else to
the downloads, as `application/octet-stream`. The relay lets app.gogho.st read its files routes' answers
(`GHOST_APP_ORIGIN`, as for feedback: `/files/` alone besides those two), and the page's policy names
`https://gogho.st/files/`; a relay's own `/app/` is the relay's own address and needs neither. What the web server in
front of the relay answers on its own (a body over its limit, a `502` while the relay restarts) carries no CORS
header, so a page across addresses sees only a failed request, which it takes as the relay out of reach: an upload
waits and tries again (gogho.st's blocks take 10 MiB a request, `tool/deploy-site.mjs`; the app's pieces are 4 MB).
Opening a file brings it into the tab only where the page shows it (`browserShowsHere`: a picture of 8 MB at most,
words of 16 MB, a sound or a video of 512 MB), and only the first 256 KB of words is read out of the tab; anything
else, or bigger, is downloaded when the person asks. What a browser keeps of
a file that came down is in the tab's memory: Chromium and Firefox put a big `Blob` on disk among the profile's
temporary files and delete it when the tab closes; Safari holds it in memory, so a very large file is better brought
down by the app. Tried by `tool/web/e2e.mjs`: one browser uploads a file to a circle's Files space, by the
picker and by a drop, the other sees it and downloads it, byte for byte, in Chromium and WebKit.

**A device's conversations** (GMFB-53): the account's backup carries friends and circles, never conversations, and the
copies an account's devices pass each other carry what is said from then on; so a device signed in on (a browser, an
iPhone, a computer of its own) asks its account's other devices for the conversations with friends they hold
(`lib/friends/friends.dart`, `mine-ask`, `mine-past`, `mine-got`), at each start that is due until an answer that
carried something has ended, or every other device on the account's list has answered with nothing. Anyone holding the
account's key can send the account anything, so the answer can't go on a device's word alone: the asking goes by the hub,
which hands it to the account's other devices with the device that sent it, as that device named itself in its hello
(`docs/network.md`, "The hub"); the account's device list keeps that hub name beside the device's number (`h`, given as
it is listed, and from its next check by a device holding the account's key that was listed before); and a device answers
only where `acct-hello` with both says they belong together. It answers each device once (again a day on only where that
device never said it had it all, which is taken only from that device for that asking), with only conversations with
the account's present friends, the newest 300 messages each, at most 12 parts of 40 KB, and Settings › Devices says
"History sent to" the device as the list names it. A relay from before keeps no hub names and stamps nothing: there
nothing is answered.

### Its address

Ours is served at **app.gogho.st**, an address of its own (`tool/deploy-site.mjs --app`, `tool/lib/web_site.mjs`),
never under gogho.st: the site's pages have scripts written into them and `/join` takes an address to dial, and the
relay's `/link`, `/files` and `/market` answer there too. A page at the same address as any of those shares the
app's store, so a script slipped into one of them could read what the app keeps, and an account's identity can't be
changed once it has been read. The build for it names its hub, `wss://gogho.st/hub`
(`node tool/build-web.mjs --app`, `--dart-define=GHOST_WEB_HUB`), and its policy lets it speak to that and to its own
address and nothing else, but for the two things it sends over plain HTTP, from the page's own `fetch`
(`lib/web/http.dart`): a report to the review, `https://gogho.st/market/abuse`, and feedback, `https://gogho.st/feedback`
(`tool/lib/web_site.mjs` `connectFor`). The relay lets app.gogho.st read those two answers, and no others
(`GHOST_APP_ORIGIN=https://app.gogho.st`: `Access-Control-Allow-Origin` on `/market/abuse` and `/feedback` alone,
`relay/lib/relay.dart`). A relay anyone runs can serve the same app from its own `/app/` (`--web`, `GHOST_WEB_DIR`),
built without a hub, which then speaks to the hub beside it; feedback goes to that relay, beside the page, and a
report can't go from there (reports go to Uplink's review, at another address its policy doesn't name), so
the report sheet says where to report from instead: app.gogho.st, or the app on a phone or a computer. Feedback from a
browser is words alone: a page can't choose a picture yet.

Both addresses tell the browser the same things on every answer (`tool/web/headers.json`, held to by
`test/web_build_test.dart` and `relay/test/web_app_test.dart`): the page's own policy as a header, with
`frame-ancestors 'none'` (the worker, `argon2id.js`, which the page's `<meta>` doesn't reach, is held to it too);
`X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`,
`Cross-Origin-Opener-Policy` and `Cross-Origin-Resource-Policy` of `same-origin`, and a `Permissions-Policy` that lets
the page itself (and nothing framed in it) ask for the camera and the microphone, for calls, and nothing for location
or the screen; `no-cache`, and a year only for the one file named by its hash. HSTS
is app.gogho.st's; a relay's own server in front of it says its own.

### What a browser keeps, and what that is worth

- **Every record is sealed** (`lib/web/store.dart`): the conversations and choices (one record, `state`, which holds
  the circles' and spaces' keys and the password-sealed copy of the backup), the identity, and every secret
  (forward secrecy's prekeys, the circles' keys, the key the account's devices seal copies to each other with). Sealed
  with AES-256-GCM under a key the browser made for the page as not extractable: the page's own code can't read the
  key's bytes out.
- **What that doesn't keep out.** Anything that runs in the page can ask the browser to open every record with that
  key, as the app does: a script slipped into the page, or a browser extension allowed to read and change pages on
  the app's address. The key is kept among the browser profile's files: in Chrome, Edge and Firefox as it is, so a
  copy of the profile opens everything; Safari wraps it with a key in the Keychain. And the page's code comes from the
  server each time it is opened: a server broken into could hand out a page that takes the password as it is typed.
  The app on a phone or a computer is installed once and changes only with an update.
- **What isn't kept at all**: the recovery words and the key the password makes (`Account.keepsWords`). They are
  opened from the password-sealed copy of the backup each time they are wanted: showing the words, a new password,
  listing or removing the devices, and bringing the backup up to date (which every other device does by itself once a
  day, and a browser only when asked, in Settings › Me). In their place a browser keeps only the key the account's
  devices seal copies to each other with, made from the words: it opens none of the account's other keys, but it
  opens every copy of what is said with friends by username, both ways, for as long as the account lasts (it never
  changes). The password-sealed copy is kept, so whoever opens the store could try passwords against it as fast as
  they like: a long password is what stands in the way.
- **Signing out deletes the whole database**, its key with it, asks the server for `Clear-Site-Data: "storage"`
  (`relay/lib/web_app.dart`, app.gogho.st's block; answered only to the page's own asking, `Sec-Fetch-Site:
  same-origin`, so a link to it from anywhere else signs nobody out), and loads the page again at the welcome; it takes itself off the
  account's devices by its own number (`acct-leave`, `relay/lib/accounts.dart`), which needs no account key. Deleted,
  the database is gone to the page and to whoever uses the browser next; Chrome kept its bytes, the key among them,
  among the profile's files for a while after, until the `Clear-Site-Data` answer took them away. On a computer others
  use, a private window, or clearing the browser's data for the app, is the safer way.
- **Removed from another device**, it does the same: a page left open within a few minutes, as soon as its tab is
  looked at again, or as the hub's connection comes back; a page closed, the next time it is opened. The relay keeps the
  account's signed removal (`acct-devices`' `remove`, kept through every backup brought up to date) and hands it to the
  device, which checks the account key's signature over its own number; each sign-in gives a device a new number, so
  no removal signed before can name it. A browser also deletes everything where the relay holds the account and
  doesn't list it, signed or not: what it keeps is a copy, and it can't be on another relay than its page's. An iPhone
  or a computer of its own deletes everything only on the signed removal; where the relay holds the account and doesn't
  list it with nothing signed (a relay from before removals were kept, a removal made before it was deployed), it forgets
  the account's words and keys and keeps its conversations, as every device did before and an Android phone still does.
  A relay that doesn't hold the account at all (another relay, one that lost what it kept) can make no device delete
  or forget anything: it says so, and offers to list the device again, which puts the account on that relay from the
  device without signing in (signing in would put the backup's friends and circles in place of the device's). The relay
  is to be deployed before an app with this (`relay/README.md`).
  A store that can't be opened (a record under another key, or changed) is deleted too, and the person is asked to
  sign in again, never made someone new under the account's choices; one that can't be read just now (busy, full) is
  not started on, and nothing is written over it.
- **One tab at a time**, by the browser's own lock (Web Locks): a browser without it is told it is too old. A tab
  that hands over stops its routes first, writes what it has, then lets go; the other waits for it.
- **Each browser signed in is a device** on the account's list (at most 20, kept until removed), with its browser's
  name and when it was last seen; a private window is a new one each time, and the sign-in page says so. The page asks
  the browser to keep its store through low space (`navigator.storage.persist()`).

## The order of work

1. Seams (`HubLink`, `HubSocket`).
2. The core and its binding; the direct route against a stand-in node. Side by side.
3. The ledger and the name watch.
4. Relays that talk; names across relays.
5. A relay hosted from the app; a hub connection over the direct network.
6. The web client, alongside all of the above.
7. Each build's packaging (Android, the Mac, Windows, Linux; the iPhone when it ships), then an independent review
   before each switch is turned on.
