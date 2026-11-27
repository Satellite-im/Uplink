# Uplink's relay

Passes sealed frames between a phone and the computer it is paired with when they are on different networks
(Matt, 2026-11-13: "I'd like to support both a relay server and local networking"; [../docs/desktop.md](../docs/desktop.md)).
Dart's own library and nothing else. It is on our server since 2026-11-14 (Matt: "Deploy the relay"), behind
ghost-sms.com: `wss://ghost-sms.com/relay` and `wss://ghost-sms.com/hub`.

```sh
dart pub get                                   # the test package only; nothing the relay itself runs
dart run bin/relay.dart --port 8787 --verbose  # ws://127.0.0.1:8787
dart run bin/relay.dart --web ../build/web     # and the app in a browser at http://127.0.0.1:8787/app/
dart test                                      # the relay and its SHA-256
dart compile exe bin/relay.dart -o ghost-relay # one file to run on a server
```

Use the `dart` that comes with Flutter (`$(dirname $(which flutter))/dart`) where another is first on the path.

**Running your own** (GMFB-25): [../docs/SELF_HOSTING.md](../docs/SELF_HOSTING.md). A Dockerfile here, and in
`deploy/` a Compose file with Caddy, a systemd unit, Caddy and nginx configs, a coturn config, and `relay.env.example`
listing every variable the relay reads (none is required). A relay is an island unless its keeper switches on talking
to other relays (`GHOST_FED`, "Other relays" below): then two people whose apps use different relays can be friends.

## The app in a browser (`/app/`)

`--web <folder>` (or `GHOST_WEB_DIR`) names a folder holding the app built for a browser (`node tool/build-web.mjs`
in the app's folder writes `build/web`), and the relay serves it as plain files under `/app/` (`lib/web_app.dart`).
A build that names no hub (the plain `node tool/build-web.mjs`) dials `/hub` where its page came from, so the page and
the hub are one address. Only GET and HEAD; only what is in the folder (no `..`, no names starting with a dot, no
links leading out of it); no lists of a folder; each file said to be what it is (`application/wasm`,
`text/javascript`, ...); `index.html` and every file whose name doesn't say what is in it asked for again each time
(`no-cache`, with a tag), a file with a hash of its contents in its name kept for a year; and `name.br` or `name.gz`
sent in a file's place where it lies beside it and the browser reads that packing. Every answer says what the app may
do (the app's `tool/web/headers.json`): the page's own policy as a `Content-Security-Policy` header, with
`frame-ancestors 'none'` (so the Argon2id worker, which the page's `<meta>` doesn't reach, is held to it too),
`X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`,
`Cross-Origin-Opener-Policy` and `Cross-Origin-Resource-Policy` of `same-origin`, and a `Permissions-Policy` that
lets the app's own page ask for the camera and the microphone (for calls, where its build has them) and nothing asks
for location or the screen. HSTS is for the web server in front of the relay to say. Behind a
web server, pass `/app/` on to the relay beside `/hub`. Without the option there is no `/app/`.

Serve it from its own address if you can (as gogho.st does: app.gogho.st, the app's `tool/deploy-site.mjs`): a page
at the same address as anything else there (a site with scripts written into it, the relay's `/link` pages) shares the
app's store in the browser, and a script slipped into one of those could read what the app keeps. A page there
sends the relay two things across addresses, a report (`POST /market/abuse`) and feedback (`POST /feedback`):
`GHOST_APP_ORIGIN` names that address (`https://app.gogho.st` for gogho.st), and the relay answers those two, and
nothing else, so the page may read them (CORS: `Access-Control-Allow-Origin` that address, a `POST` with the app's
signature headers). Without it, the page at its own address can send neither. A build with Files spaces (every
`tool/build-web.mjs` build but `--no-files`) also lists, reads and writes a space's files there: the relay answers `/files/<space>…`
to that address too (`GET`, `PUT`, `POST`, `DELETE`, with the space's token, a `Range` and the signature's headers),
and still asks every request for the token and every write for its signature.

What the web server in front of the relay answers on its own carries no CORS header: a body over its limit (`413`
from Caddy's `request_body`), a `502` while the relay restarts. A page across addresses is shown none of those, only
a failed request, which the app takes as the relay out of reach (an upload waits and tries again). gogho.st's blocks
(`tool/deploy-site.mjs`) let a Files request carry 10 MiB, over the app's pieces of 4 MB and their seals.

## The hub

The same program also serves **the hub** at any address ending `/hub`: where two people's apps find each other
through this server (Matt, 2026-11-14: "for right now we can use our servers to negotiate calls through the app").
It is `lib/hub.dart`, with its own signature checking in `lib/p256.dart`, and is described with the rest of the
app's routes in [../docs/network.md](../docs/network.md). Behind a web server it needs one more line beside the
relay's: in Caddy, `handle /hub { reverse_proxy 127.0.0.1:8787 }`. What it holds for people who are away is in
memory: at most 96 MB of packets (each counted with 256 bytes for what holding it costs), and 20,000 connections. On disk it keeps the relay's own key and the home records
people gave it where it talks to other relays (`relay-key.json`, `homes.json`: "Other relays", below), and the names
of the accounts that sign in bound to it (`hub-v2.json`, below).

**No message longer than a door takes is held** (`lib/ws_door.dart`, found in the review of 2026-11-22). Dart's
WebSocket holds a whole message before anything can look at its length, so every door takes the socket from the
upgrade itself, answers it as Dart's own upgrade does (101, the key's accept, no extension: compression is off
everywhere), and reads the frames' headers before the parser does: a message longer than the door takes ends the
connection before a byte of it is held. The hub takes a megabyte (the longest an app says is a watch list of 5,000
keys, about 340 KB), a pairing's door a frame of a megabyte and 64 KB, a link this relay dialled 128 KB; the first
message at any door (a hello) 16 KB; no door a message in more than 1,024 pieces, a control frame over 125 bytes, or
bits an extension would use.

**Nor more than the relay has, all connections together** (`WireBudget` in `lib/ws_door.dart`). A door's ceiling
bounds one connection, but twenty thousand connections at a megabyte each would be far more than the relay's 300 MB. So
what every connection holds is counted against one budget for the whole process: the part of a message that has come in
and isn't finished, and what waits to go out (the answers to a peer's pings included: Dart answers each ping by itself).
Everything written to a connection waits where it is counted, never inside Dart's own WebSocket.

A connection is ended for what it holds only as these say, never for a burst it is being given (the second review,
2026-11-23, found the first version ending a phone handed a room's kept messages in one go):
- more than 8 MB waits to go out to it, for 10 seconds on end, whether it reads some of it or not;
- a message coming in hasn't grown by 16 KB (or been finished) for 20 seconds, signed in or not;
- all of them together are past 64 MB: those stalled longest go first (what waits for them hasn't gone down by 64 KB,
  or what comes in grown by 16 KB, for 2 seconds or more), then those holding most of all, past a megabyte each (or a
  32nd of the budget), until the rest fit.

An ending is counted at once, and the socket destroyed a moment after, never in the middle of a room's broadcast (the
third review found the list of members changed under one). A connection whose own answers wait past a megabyte is not
read from until they are under 256 KB again, so a peer flooding pings, or anything else that is answered, limits
itself, signed in or not.

The hub hands over what it keeps (a room's kept messages, what was held for someone) only as fast as the connection
takes it: a piece at a time while less than 256 KB waits for it and the budget has room, so a device that reads holds a
few hundred KB at most. What is said to it meanwhile waits behind the hand-over, in order and counted, so nothing said
live overtakes what is being handed over (a deletion never comes before the message it deletes). Once the hub closes a
connection nothing more is written to it, and what it wasn't handed of its held packets is kept again at once, before
the same device's next connection takes them. The numbers are settings: `GHOST_WIRE_MB`, `GHOST_WIRE_EACH_MB`,
`GHOST_WIRE_STALL_S`, `GHOST_WIRE_IN_STALL_S`.

A ping or pong with something in it that comes between the pieces of a message (a browser may split a long one) is
handed on after the message's last piece: Dart's parser alone lost the message's first pieces to it, into its answer
to the ping. An empty one (the answer to the relay's own pings) goes through at once, as a Close does.

**Signing in.** An app signs the hub's number with its key. Before 2026-11-23 that signature (v1) was the words
`ghost-hub v1 ` and the number, and said nothing of where it was made, so a relay an app was pointed at, or asked a
name of, could hand the app the number of the app's own relay and sign in there as the app with the answer. So a hub
that knows the names it is reached at (`GHOST_HUB_NAMES`) says so in its hello, and an app signs to it bound to the
host it dialled (v2):

    {"hello": <64 hex>, "peek": true, "react": true, "v2": true, …}
    {"id", "key", "sig", "v": 2, "host": "gogho.st", "device", "mode"}
      sig over "ghost-hub v2 " | len(host) (1 byte) | host | the number (32)

The host is what the app dialled, in lower case, with its port only where it is not the scheme's own. The hub takes a
v2 signature only for a host in its own names (`This relay isn't reached as …` otherwise, whatever the request's
own Host header says, which the one signing in writes), and **from a key that has signed in with v2 it takes no v1
again** (`This account signs in a newer way now: update Uplink on this device.`): the names are kept in
`hub-v2.json` across restarts. So once an app of this build has signed in to its relay, a v1 signature it gives
anywhere else is worth nothing there; an app from before keeps signing v1, and keeps working for an account none of
whose devices has signed in with v2.

Those names are hard to push out with keys made for it (the second look and the second review, 2026-11-23): at most
200,000 are kept, and past that **a key that has held a username here for two days stays longest**; one holding none, or
one taken a moment ago, goes first, the one seen longest ago; **one place adds at most 30 new keys an hour, and all of
them together 5,000**, a place being an IPv4 address or an IPv6 address's first 48 bits. A sign-in past that is taken
all the same, its key kept the next time it signs in with room. The place is the connection's own address, or, where it
came through a proxy on the same machine or its private network (Caddy, in front), the last address that proxy put in
`X-Forwarded-For` (the one it saw: whatever comes before it is the asker's own word).

The kept keys are held to **only while names are set**: a hub with no names offers no v2, so every app signs v1 to it,
and is taken; set the names again and the keys kept meanwhile are held to again. A v1 sign-in from a kept key is refused
before its signature is checked, and an app refused again within the hour is answered two minutes late, the connection
open meanwhile (an app from before tries again half a minute after a refusal, for ever; this way it comes back a few
times an hour), at most 1,000 waiting at once. A closed app's look (`peek`) is held to the same, and Android's
background check signs v2 as the app does; so does the browser extension (`extension/src/ghost/relay.ts`), from 0.2.2.

**Switching v2 on**, in this order: (1) ship builds that sign v2 everywhere (the app on every platform, Android's
background check, the extension) and wait until most people have them, since from a key's first v2 sign-in on, every
older build of that account is refused (each device is told to update); (2) set `GHOST_HUB_NAMES` to **every** name the
hub is reached at, without ports where it is 443 (for gogho.st: `gogho.st,www.gogho.st,ghost-sms.com,www.ghost-sms.com`):
an app that dialled a name not listed is refused, and doesn't fall back to v1. A name must stay registered to you for as
long as it is listed: whoever held it next could take a v2 sign-in made for it. Taking the names away again (or an env
file that leaves them out: the deploy's `--env` replaces the box's whole environment) turns the hold off, not the keys.

**A relay hosted from the app** (the app's `lib/relay_host`; [../docs/OPEN_NETWORK.md](../docs/OPEN_NETWORK.md), section
5) is this same hub run inside the app, which asks four things of it. Each is a setting of `Hub` that does nothing unless
it is set, and `bin/relay.dart` sets none of them: a relay on a server, gogho.st's, says and does what it did.

- `pass`: a pass phrase everyone who uses the hub must give. The hello says so (`"pass": true`, with `"salt"`: the
  relay's own, `passSalt`, its name where it has one), and a sign-in, or a closed app's look, is taken only with
  `"pass"` in it: HMAC-SHA256, under the phrase made into a key (PBKDF2 with HMAC-SHA256, `ghost-hub pass v2 ` and the
  salt its salt, 20,000 rounds, 32 bytes), over `ghost-hub pass v2 `, the hub's number for that connection and the
  install's name (16 bytes), in hex. So it is good for that connection and that install alone, and nothing of the
  phrase crosses; seen on a local network it can be tried against as fast as the rounds allow, for that relay alone (a
  list of likely phrases made into keys once is no use against another), so a long phrase is what stands in the way.
  None given is answered `{"ok": false, "err": …, "pass": "needed"}` and counts for nothing; a wrong one `"pass":
  "wrong"`, and costs whoever gave it: each place (a network address; over Direct the node) has 5 free, then each try
  waits a minute, doubled with each wrong one, at most an hour; and strangers together (installs that never gave the
  phrase here) have 200 an hour, past which a stranger's isn't read until the hour is out. An install that has given
  the right phrase here (kept in `hub-pass.json`, under a tag of the key, so a new phrase starts it again) is read
  still, and the keeper's own app in memory (`attach(own: true)`) is never asked: a stranger can hold newcomers off for
  an hour at a time, never those who use it. A try that isn't read is answered `"pass": "busy"` with `"wait"`, the
  seconds until it would be. Each refusal closes the connection (4401). Another relay's hello is not asked for it:
  whether relays link is their keepers' own choice.
- `attach(reachedAs:)`: a connection taken knowing how the app at the far end named this relay's place (the node id
  its Direct connection came in at, or the relay's name in memory): the hello carries `"relaySig"`, the relay key's
  signature over `ghost-hub relay v1 `, the connection's number and that place, which an app dialling
  `ghost-relay://<name>?n=<node>` checks against the name, the key and the node it dialled. Nothing where it isn't
  given or the relay has no key.
- `hosted`: the hello says it runs in someone's app (`"hosted": true`), so whoever joins is told that whoever runs it
  sees which installs talk and when (never what), and that it is up only while their app is.
- `roomKeepBytes`: what rooms keep, all of them together (256 MB unless given less).
- `trustsProxy: false`: `X-Forwarded-For` is not believed (the place a connection counts as, above): with nothing in
  front of the hub, anyone on its network could write anything there, and be a new place each time they tried.

## Other relays

Relays that pass sealed packets to each other, so two people whose apps use different relays can be friends and talk
(Matt, 2026-11-22: "I'd like the relays to be able to talk to each other"). It is `lib/federation.dart`, with the home
record in `lib/home_record.dart` and the rules for dialling out in `lib/fed_dial.dart`; the plan it follows is
[../docs/OPEN_NETWORK.md](../docs/OPEN_NETWORK.md), section 4 (the code differs where it is safer: what the review of
2026-11-22 asked for). **Off unless `GHOST_FED` is set, and off it does nothing at all**: no key is made, no record
kept or answered (`home` and `home?` are answered as a relay from before answers them), no `relay` in the hello, and a
relay's hello is a bad hello (4400), as it always was.

**A key of its own.** `relay-key.json` in the data folder, made on first start: the file is made empty, its mode set
to 600 (the C library's `chmod`; said loudly where it can't be), and only then written; nothing is changed for the
rest of the process. On Windows it is an ordinary file. `{"v":1,"id","key","scalar"}`. The relay's name is the first
16 bytes of the SHA-256 of its public key, in hex, as an install's is; it prints it as it starts ("this one is …"). Keep
the file: a relay that loses it has a new name, and other relays' lists that name it no longer do. One that can't be
read is put aside as `relay-key.json.broken-<ms>`, never written over. The hub's hello says who the relay is:

    {"hello": <64 hex>, "peek": true, "react": true,
     "relay": {"id", "key", "url": its hub's address (with GHOST_PUBLIC_HUB), "via": (with GHOST_FED_VIA), "fed": true}}

**Home records.** Where an account lives, signed by the account, and the only thing a relay believes about it:

    {"v":1, "a": account name, "k": public key (33 bytes, base64), "h": [1 to 3 addresses], "n": count, "t": made (ms), "s": signature}

signed over `"ghost-home v1\n"`, then the name (16 bytes), the count (4 bytes, big end first), the time (8 bytes), how
many addresses (1 byte), and each address as its length (1 byte) and its bytes. A record is kept only where the name is
the key's, the signature is that key's, each address is at most 200 printable characters, its time is no more than
five minutes ahead, and it is **good: thirty days from its time** (after that it says nothing, so a relay someone left
can't speak for them by an old record however long ago the newer one was forgotten; the app makes the next well
before). Of two for one account the one believed is the higher count, then the later made, then the greater signature
byte by byte, so every relay believes the same one. An address is a hub's (`wss://host/hub`) or a relay hosted from an
app's (`ghost-relay://<relay name>?n=<node id>&via=<the public relay it stays linked to>`). The app makes and checks
the same bytes, and both are held to `../test/home_record_vectors.json`.

What an app says of them over its hub connection:

| An app says | The relay answers |
|---|---|
| `{"dir":"home","rec": record}`: its own, or a friend's so the relay can route to them | `{"dir":"home","a","ok":true,"n": the count held}`; or `"ok":false` with `"err"`: `bad` (not a record), `old` (ended), `busy` (too many checks just now: give it again) |
| `{"dir":"home?","a": its own name}` | `{"dir":"home?","a","rec": record}` or `"none":true`. Asked of anyone else's, `"none":true`: nobody is told where anyone lives but over a link, or with the username they chose to be found by |
| `{"dir":"whois","name":"maya"}` (a name here) | as ever, with `"home"`: the holder's record where one is held |
| `{"dir":"whois","name":"maya","at":"relay.example"}` | `{"dir":"whois","name","at","id","key","home"}`; or `"none":true`, with `"why"` where it is not that nobody has the name: `off` (this relay doesn't talk to that one), `refused` (that one won't), `down`, `busy`. An `at` that is this relay itself is an ordinary lookup, answered with `"at"` and `"here":true`; an error about one carries `"at"` too |
| `[1][number][to][packet]` to someone who lives elsewhere | `{"ack": number,"here":false,"fed":true}` (taken by their relay: whether they are connected is not said across relays), with `"waiting":true` where it waits on this relay for theirs; or `{"nak": number,"err"}`: `home` (no record of the sender's naming this relay is held: give it, and send again), `busy` (past what one install or one place may send across relays, or the new relays it may make this one dial, or what installs not yet established share), `full`, `far` (their relay is one this relay can't or won't pass to, or an address never once reached), `refused` |

Records of people who gave theirs here themselves are kept in `homes.json` (the newest 20,000 given, with when each
was first given here); others' (a friend's, one another relay gave) are the 10,000 used most lately, in memory.
`homes.json` and `hub-v2.json` are logs of what changed (`lib/kept_log.dart`): a line appended for each change, a
couple of seconds' changes at a time, and written whole again, once the log has grown far past what stands, in an
isolate; the whole is never written on the event loop (found in the second review, 2026-11-23: at their largest the
two were 7 and 22 MB, rewritten whole within two seconds of any change). A file of the kind written before is read, and
written as a log from the next change. A record's shape and time are looked at
before anything is counted; then the giver's own checks (600 an hour for an install, and a quarter of any second's;
ten times an install's, and half a second's, for a linked relay at an address this relay has checked; one install's
for every relay with no address together); then everyone's (20 a second); and only then the signature.

**A link** is one relay dialling another's hub address and saying, in place of an app's hello:

    {"fed":1, "id", "key", "sig", "url": its own hub address (where it claims one), "c": <64 hex> it made up, "stay": true (to stay linked)}
      sig over "ghost-fed-dial v2 " | the hub's number (32) | its own name (16) | the answering relay's name (16) | c (32)
               | stay (1 byte: 1 or 0) | len(the address it dialled) (1) | the address it dialled | len(url) (1) | url
    {"ok":true, "fed":1, "id", "key", "sig", "stay": true (where it asked to stay, and may)}
      sig over "ghost-fed v2 " | c (32) | the dialler's name (16) | its own name (16) | len(the address dialled) (1) | the address dialled
    {"ok":false, "err"}: no address, busy, bad hello, self, bad address, blocked, not listed, address; then closed (4403)

Each proves it holds its key, over a number the other made up, over both names, and over **the address that was
dialled**: the relay answering takes a hello only where that address is its own `GHOST_PUBLIC_HUB`, and a relay with
none takes no relay's hello at all; the dialler takes an answer only where it was signed for the address it dialled.
So what is signed for one link is no use on another, nor passed on word for word by a relay in the middle, and `stay`
can't be added on the way. A relay that claims a `url` is believed only once this relay has dialled that address itself
and seen the same key in the hub's hello there (remembered for an hour; looked at again after five minutes where
another key was seen). **What is for an address goes only over a link this relay dialled there itself**, never over
one that came in claiming it: two relays that talk both ways hold two links. A hub that repeats this relay's own name
is taken to be this relay only where the number in its hello is one this relay's own hub made up. A link is opened
when first needed, kept while used, closed after ten minutes idle; a relay that can't be reached is tried again after
5 seconds, then twice as long each time, ten minutes at most (an address never once linked with is given up after
four tries and not dialled for ten minutes); one that answered no is not asked again for ten minutes. At most 64 links.

**What crosses a link:**

    [5][number: 4][to: 16][from: 16][packet]             -> {"ack": number} (taken) or {"nak": number, "err"}
    [6][number: 4][to: 16][from: 16][relay: 16][packet]  the same, for someone on a relay that stays linked to this one
    {"fed":"home", "rec": record}                        a record given: whom the sender speaks for, or where someone lives
    {"fed":"whois", "q": n, "name"}                      -> {"fed":"whois", "q": n, "id", "key", "home"} or {"fed":"whois", "q": n, "none": true}
    {"ping": n}                                          -> {"pong": n}: a number or 32 characters, sixty a minute

- **Passing on.** A packet from someone signed in here whose record names this relay, for someone not connected here
  whose record names another relay, goes to that relay as a `[5]`, after the sender's own record. That relay hands it
  to their connected devices or keeps it in their mailbox exactly as it would its own, under the same limits, stamped
  with the `from` it was given, and only for someone who has signed in there (here now, seen since it started, holding
  a username, or having given their own record): a name a stranger made up gets `nak` `to`.
- **A relay speaks only for its own people.** A `[5]` whose `from` has no record naming the sending relay (its
  address, which this relay has seen its key at) is refused: `nak` `home` (`busy` where this relay was too busy to check
  the record it was just given: sent again in a while). The sender gives the record and sends once more.
- **One hop.** What another relay passed here is never passed to a third. For someone not here whose record names
  another relay, this relay says that record and answers `nak` `moved`, and the sender routes it there itself, once,
  held to what it was held to the first time.
- **`via`, and standing links.** A relay with no address of its own (`GHOST_FED_VIA`, as one hosted from an app has)
  dials a public relay and asks to stay, and sends everything not for its own people through that link. Whether it
  may stay is **the public relay's `GHOST_FED_STANDING`, off unless set**: with it on, the hosted relay's people
  (records `ghost-relay://<its name>?…&via=<that relay>`) are reached over the standing link, another relay reaches
  them by sending the public one a `[6]` naming the hosted one (passed only to that relay, linked now or kept for it,
  and only for someone whose own record says so: `nak` `to` otherwise), and the public relay passes on what the hosted
  one's people send, to the relay their friend lives on and no further. Off, a relay with no address is linked as any
  other and is no way through: `far`. The hosted relay believes the relay it stays linked to as an app believes its relay.
  The public relay's yes says whether one that asked to stay may (`"stay": true`, said only where it may: a relay from
  before says nothing, and is read as no). Whoever runs the hosted one is shown how its link stands
  (`Federation.viaLink`): up, and whether it may stay; or why not, `down` where nothing answered, else what the public
  relay said (one with federation off answers "not a relay that talks to others"), and when it is dialled next.
- **Unreachable.** With the other relay down the packet waits here and the sender is told it is kept (`waiting`), for a
  relay linked with before: 2,000 packets or 16 MB for one relay, seven days, 32 MB for all relays together, a quarter
  of it at most for what other relays asked to be kept (linked or not); what is on its way over an open link counts
  too, 64 MB in all; each packet counted as its bytes and 384 more. One recipient, and one sender, have a mailbox's
  worth of it (200 packets, a megabyte) at most. An address never once linked with keeps what is for it a minute or two
  and tells its senders it can't be reached.
- **Other `nak`s:** `limit` (over what this relay takes from that one: the sender leaves it alone 15 seconds, then
  twice as long each time, an hour at most, and then sends one packet to see before the rest), `full` (their mailbox,
  or what is kept, is full), `big`, `far`. A frame far past what a packet can be closes the link.

**Allowances.** Everything someone else can grow is counted and capped, and no shared allowance can be used up by one
party for nothing: a hello's shape is looked at before anything is counted, and in `list` mode the list before
anything is checked or dialled; a hello is checked before it is counted, strangers' share thirty a minute, and a relay
at an address this relay has seen its key at has thirty of its own. Each install may make this relay dial eight new
relays an hour, and send a quarter of a minute's packets and an eighth of a day's bytes across relays; and installs cost
nothing to make, so one place (an IPv4 address, or an IPv6 address's first 48 bits, through the proxy in front as the
hub counts it) has twice that, all its installs together, and installs not established here have half of the new
relays dialled a minute, and half of what may go to each other relay in a minute and in a day, all of them together:
the rest is always there for those who are (an install that has held a username here, or given its own record here,
for two days, as this relay saw it, never as the install says). Per linked
relay, counted by the address this relay has checked it at (every relay with no address shares one): packets a minute,
bytes a day, names asked after an hour, records a minute. Dials are of three kinds, each its own a minute: a relay's
own (30), its tries again (30), its looks at an address another relay claims (10; an address that showed nothing is not
looked at again for ten minutes).

**Dialling out.** The addresses dialled come from other people (a record, a name typed after an `@`, the address a
relay claims), so each is held to this before anything is dialled: `wss://` only, port 443, a path ending `/hub`, no
user, query or fragment; the name is looked up here and **every** answer must be a public address (not loopback,
private, link-local, unique-local, carrier NAT, a documentation or reserved range, nor an IPv4 one of those written as
IPv6); the connection is then made to the address that was checked, never looked up a second time, with TLS still
checking the name; the handshake is made here, and only a 101 is taken (a redirect anywhere is a refusal); ten seconds
for all of it.

| Variable | Default | What |
|---|---|---|
| `GHOST_FED` | `off` | `off`: an island, and nothing of this at all. `open`: links with any relay that proves its key, but those blocked. `list`: only those in `GHOST_FED_ALLOW` |
| `GHOST_PUBLIC_HUB` | none | This relay's own hub address as the world reaches it (`wss://relay.example.com/hub`). Without it the relay claims none: it can ask other relays who someone is, but can't pass its people's packets to them, and takes no relay's hello |
| `GHOST_FED_ALLOW` | none | With `list`: hosts (`relay.example.org`, or with a port) or relays' names (32 hex), commas between. One listed by name alone is dialled at an address to learn its name there |
| `GHOST_FED_BLOCK` | none | Never linked with, whatever the mode: hosts or relays' names |
| `GHOST_FED_PACKETS_A_MINUTE` | 1200 | Packets one linked relay (one checked address) may pass here in a minute; each of your own people may send a quarter of it across relays |
| `GHOST_FED_BYTES_A_DAY` | 536870912 | Bytes one linked relay may pass here in a day; each of your own people may send an eighth of it across relays |
| `GHOST_FED_LOOKUPS_AN_HOUR` | 600 | Usernames one linked relay may ask after in an hour |
| `GHOST_FED_PORTS` | none | Ports dialled besides 443, commas between |
| `GHOST_FED_PLAIN` | `0` | `1` lets `ws://` (no TLS) be dialled: only between machines you run yourself |
| `GHOST_FED_VIA` | none | For a relay with no address of its own: the public relay it dials and stays linked to |
| `GHOST_FED_STANDING` | `off` | Which relays with no address may stay linked to this one, their people reached and their packets passed on under this relay's name: `open`, or relays' names, commas between. For relays hosted from the app |
| `GHOST_HUB_NAMES` | none | The hosts the hub is reached at, commas between: with them it takes a sign-in bound to the host dialled ("Signing in", above) |

What it adds to what a relay can see: which of its people talk to people on which other relay, and when. Never what.
What waits for another relay, the links, and others' records are in memory: a restart loses them, as it loses what the
hub held (unless `GHOST_HUB_KEEP_HELD=1`: "What it keeps"), and each app says where its friends live again as it signs in.

**Not built:** rooms across relays (circles, spaces, calls stay on the relay they were made on), who is here across
relays, and an account signing in on another relay than the one it was made on.

## What an end says to it

1. It opens a WebSocket at any address ending in the channel: `ws://host/relay/<32 hex digits>`.
2. Its first message, as text: `{"auth":"<64 hex digits>","role":"phone"|"desk"}`, with `"temp":true` for a channel
   made for pairing. The relay answers `{"ok":true,"peer":true|false}`, or `{"ok":false,"err":…}` and closes.
3. Binary messages go to the other end as they are. With the other end away the sender gets `{"dropped":true}`.
4. The relay says `{"peer":true}` and `{"peer":false}` as the other end comes and goes.
5. `{"delete":true}` removes the channel (unpairing). `{"ping":n}` is answered `{"pong":n}`.

## What it keeps, and what it can see

`relay-data/channels.json` holds, for each pairing, the channel, the SHA-256 of its token and the day it was last
used. No frame is written or held; no address is logged. It can see that two addresses share a channel, when, and
how much they send. A pairing's channel is removed by unpairing or after ninety days unused; a pairing-time channel
lives ten minutes and is never written.

**The hub's packets for people who are away**, and what a room keeps for whoever joins later (a space's words,
deletions, roster and reactions), are held in memory, and a restart loses them, unless the relay's keeper sets
`GHOST_HUB_KEEP_HELD=1` (off by default; `lib/held_store.dart`). Then they are on the machine's disk too, under
`<data>/held/` (`/var/lib/ghost-relay/held` on the box), for as long as the hub holds them: until handed over, and
never more than seven days. Each is kept exactly as sealed by the apps, which the relay cannot open, with what is
needed to hand it over: for a packet held for someone, **whose name it is for, whose name sent it** (as the hub
stamped it), when it came, and, for one an account sent to its own name, which of its devices sent it; for a room's,
the room's name, the SHA-256 of its token and when it came. Nothing else: no address, no username, no number. So
with it on, anyone who can read the box's disk can read who wrote to whom, and when, for the last week, as anyone
who can read the relay's memory always could; with it off that goes with each restart.

It is written as append-only files, each record its length and a CRC-32: a stop (SIGTERM) writes everything, a crash
or a `kill -9` loses at most the last fifth of a second, and a file torn half way is read up to the tear and the rest
passed over. Whatever is handed over, expires, or is pushed out by a limit is marked gone on the disk too, and the
oldest file is written again into the newest (what still stands in it) and deleted whenever the files hold more than
twice what stands plus 16 MB: the disk holds about twice what is held, at most, and what is held has the same limits
as in memory (200 packets or 1 MB a person, 96 MB in all with 256 bytes counted for each, rooms 300 packets and
256 MB), which are kept again as the
hub starts, with anything past seven days dropped. A packet handed over in the last fifth of a second before a crash
may be handed over again after it (the apps pass over a packet they have had already: the app's
`lib/net/switchboard.dart` and `forward_secrecy.dart`). Holding a packet costs about 5 µs
more with it on, and writing what waits about 2 ms a megabyte (`dart run tool/held_store_bench.dart`); a packet to
someone who is connected is never written. After a clean stop the hub's `since` (said with every sign-in) is the
start of the hub before, since nothing it kept went with the restart; after a crash, or where another relay's packets
waited in memory, it is the new start.

## On our server

**Deploy the relay before any app that deletes an account from a removed device** (the `web` branch's change; the
app's `lib/account/account.dart` `check`). Such an app deletes everything of the account from an iPhone, a computer of
its own or a browser only on the account's own signed removal, which the relay keeps (`acct-devices`' `gone`) and
hands back with `acct-hello`. A relay from before hands out none: under it a removed iPhone or computer only forgets
the account's words and keys, as the release before did, and nothing is deleted. A removal made before this relay was
deployed was never kept either: those devices do the same. The same deploy keeps push tokens one per device
(`pushes.json`, read as it was), answers `/app/clear-site-data` only to the page itself, and needs
`GHOST_APP_ORIGIN=https://app.gogho.st` in its env for app.gogho.st's reports and feedback (`deploy-relay.mjs --env`
replaces the whole file: put the rest of it in too).

    node tool/deploy-relay.mjs --keep-connection && node tool/deploy-site.mjs --caddy   # the first time: one login
    node tool/deploy-relay.mjs                                                          # after that, when relay/ changes
    flutter test tool/net/live_hub_test.dart --dart-define=HUB=wss://ghost-sms.com/hub  # two made-up installs through it

`tool/deploy-relay.mjs` builds the relay for the box from the Mac (`dart compile exe --target-os linux
--target-arch x64`), and in one ssh session checks it arrived whole and runs there, that its port is its own or
nobody's, then installs it: a user of its own with no shell (`ghost-relay`), the program in `/opt/ghost-relay`,
what it keeps in `/var/lib/ghost-relay`, and a systemd service (`ghost-relay`) that restarts it, may write nowhere
else, and may use 300 MB and one processor. It listens on `127.0.0.1:18787`: 8787 is another site's on that box,
which the first deploy found and stopped at before changing anything. `tool/deploy-site.mjs --caddy` writes
`@relay path /hub /relay/*` and `reverse_proxy 127.0.0.1:18787` into ghost-sms.com's own block of the shared
Caddyfile, with that script's backup and its asking of every other site before and after.

Done 2026-11-14 04:35 UTC, in one login: the service up, every other site on the box answering as before, and
from outside `https://ghost-sms.com/relay/` and `/hub` answering "Ghost Messaging relay". The live check signed in
in 380 ms, had a packet held for someone away and handed over, one passed and answered in 164 ms, and a room
joined by two and left. A restart of the service drops whoever is connected (the apps connect again by
themselves) and loses what the hub held, unless `GHOST_HUB_KEEP_HELD=1` keeps it on disk ("What it keeps", above).

### The Marketplace (`/market`)

Plugins from other developers and their review (Matt, 2026-11-20: "I would like users to be able to develop and
submit their own plugins to our plugin marketplace and I'd like to be able to verify them for the store through a
review process"): `lib/market.dart`, with the checks of a pack it shares with the app in `lib/market_pack.dart` and
what it keeps in `lib/market_store.dart`. Plain HTTP under `/market`, which `tool/deploy-site.mjs --caddy` passes on
with Files' and feedback's routes. [../docs/marketplace.md](../docs/marketplace.md) is the maintainers' note.

**What it keeps**, in `<data>/market` (`/var/lib/ghost-relay/market` on the box): `state.json` (plugins, submissions,
developers, reports, withdrawals and retired keys), saved after each change, with `state.json.bak` the copy before
it; `packages/<sha256>` and `shots/<sha256>`, each package's canonical bytes and each screenshot, named by the SHA-256
the relay worked out itself; and `audit.jsonl`, a line for each thing done (when, by whom, what, which plugin and
submission). Where neither state file can be read, both are put aside as `*.broken-<ms>` and it starts empty, still
knowing from the audit which developer sent which plugin id. Nothing it holds is secret beyond what the admin session
already guards: a package and its screenshots are public once listed, and until then only their developer and review
are shown them. Nothing records which address read what, nor who sent a report (only the username they chose to send
with it; the audit's line for it says `reporter`). Stopping lets route 8's queue finish first (10 seconds at most), and
answers anything new busy; whatever still finishes after the last save is written as it finishes.

**Who may do what.** Anyone reads what is listed. Everything else is signed with the asker's hub key: `x-ghost-key`
(base64 of the 33-byte key), `x-ghost-time` (ms) and `x-ghost-sig` (base64 of the 64-byte signature, r then s) over

    ghost-market v1\n<METHOD>\n<path as asked, never with a query>\n<time>\n<the body's SHA-256 in hex>

and a request with a body says that hash and its length up front, in `x-ghost-body-sha256` and `x-ghost-body-length`,
so all of it is checked before a byte of the body is read, cheapest first, and a request refused is refused unread. A
developer submits only under a username their key holds, a week after it was claimed. Review is whoever signed in to
the admin page over the hub (Settings › Admin, the @matt account and the admin password) in the last 8 hours, and in
the last 30 minutes to approve, list, withdraw or block: no password travels over HTTP, and a restart signs everyone
out. An approval is the reviewer's own signature over `ghost-market approve v1`, the plugin's id, its version and its
package's SHA-256, which every app checks with the review keys it ships with, at install and at every load: this server
can withhold a plugin, never make one reviewed.

| # | Route | Who | What |
|---|---|---|---|
| 1 | `GET /market` | anyone | what it takes: the format, the limits, the vocabularies, whether it is open |
| 2 | `GET /market/catalog` | anyone | the listed plugins: id, version, SHA-256, size, approval; `ETag`, 304 |
| 3 | `GET /market/revoked` | anyone | the withdrawals and the retired keys; `ETag`, 304 |
| 4 | `GET /market/packages/<sha256>` | anyone | an approved package (410 once withdrawn) |
| 6 | `GET /market/shots/<sha256>` | anyone | a listed plugin's screenshot |
| 7 | `POST /market/report` | signed | a report of a plugin |
| 8 | `POST /market/submissions` | a developer | a submission, or a check of a package before the form is filled in |
| 9 | `GET /market/mine` | signed | one's own submissions and plugins |
| 10 to 12 | `GET /market/submissions/<sid>`, `…/package`, `…/shots/<n>` | its developer, or review | |
| 13 | `DELETE /market/submissions/<sid>` | its developer | withdraw it |
| 14 | `GET /market/review` | review | the queue |
| 15 | `GET /market/review/<sid>` | review | one, with the version before it and what review asked last time |
| 16 | `POST /market/review/<sid>` | review (30 minutes to approve) | start, approve, ask for changes, reject |
| 17 | `POST /market/plugins/<id>/listing` | review (30 minutes), or its developer | list or unlist |
| 18 | `POST /market/plugins/<id>/revoke` | review (30 minutes) | withdraw an approved version |
| 19, 20 | `GET /market/reports`, `POST /market/reports/<rid>` | review | the reports, and marking one done |
| 21 | `POST /market/developers/<id>/block` | review (30 minutes) | block or unblock a developer, unlisting their plugins with it |
| 22 | `POST /market/retire` | anyone | a review key's own retirement, for a key that has signed something here |
| 23 | `POST /market/abuse` | signed | a report of a person or a message (GMFB-40), `{sealed}`: sealed in the app to the review keys, unreadable here; 5 an hour and 15 a day a key, 20 a day an address, 15 a day a number or account, `REPORTS_A_DAY` for those with neither; the newest 150 kept, who sent them never |
| 24, 25 | `GET /market/abuse`, `POST /market/abuse/<rid>` | review | the sealed reports of people, opened on the reviewer's device, and marking one done |

Answers are JSON, `{"ok": true, …}` or `{"ok": false, "error": "<code>", "message": "<plain words>"}`; packages are
`application/octet-stream` and screenshots `image/png`, and nothing uploaded is ever served as anything a browser
would run (`nosniff`, a sandboxing CSP).

**Limits**, each with a default (`GHOST_MARKET_*` in the env file, which tool/deploy-relay.mjs's KNOWN lists): `ON` (0
closes it), `MAX_PACKAGE`, `MAX_SHOT`, `MAX_SHOTS`, `MAX_BODY` (held to Caddy's 10 MiB), `TOTAL`,
`BYTES_PER_DEVELOPER`, `SUBMISSIONS_A_DAY`, `SUBMISSIONS_PER_ADDRESS`, `OPEN_PER_DEVELOPER`, `OPEN_PER_ADDRESS`,
`OPEN_TOTAL`, `OPEN_UNVERIFIED`, `NAME_AGE_DAYS`, `PLUGINS_PER_DEVELOPER`, `MAX_PLUGINS`, `SIGNED_AN_HOUR`,
`SIGNED_PER_ADDRESS`, `VERIFY_A_SECOND`, `BODIES_IN_FLIGHT`, `READS_PER_MINUTE`, `REPORTS_A_DAY`, `NEED_VERIFIED` (1
takes plugins only from developers with a verified number, as it should be once it opens) and `REVIEW_KEYS` (the keys
whose approvals and withdrawals it takes; empty, the signed-in admin's own). Its rate counters are in memory and go
with a restart. A body over 64 KiB holds one of `BODIES_IN_FLIGHT` slots while it is read and until its route is done
with it (a submission waits its turn at route 8 with its body in memory): one at a time from one address and from one
key, and it must bring 64 KiB (or the rest of it) every 10 seconds, so a body trickled a byte at a time can't keep a
slot. A signing header sent twice is a 400. A package's check keeps its first hundred problems and says how many more,
so a stranger's package of thousands costs an answer of a few KB. The withdrawals list is never longer than an app
reads (8 MiB as served, 25,000 withdrawals, 100 retired keys, the app's `MarketReads`): one more is refused,
`withdrawals_full`, where review sees it. A path whose escapes aren't UTF-8 is a 400 before anything is routed, and
an error no module caught is a line on stderr, never the end of the relay.

**The sweep**, daily, the first an hour after a start: a rejected, withdrawn or replaced submission closed over 30 days
ago loses its package and screenshots, unless an approved version or another kept submission uses them (its record and
notes stay); a plugin id with nothing approved is let go 30 days after its last submission closed, or after it was
made where it never got one (the relay stopped between a submission's writes and its record); and any package or
screenshot nothing names is deleted.

    flutter test tool/net/live_market_test.dart --dart-define=MARKET=https://gogho.st/market   # after a deploy, by hand

The live check reads what anyone may, asks as a throwaway key for its own submissions, and submits and retires
nothing. Shipping the market is `node tool/deploy-relay.mjs`, and its route `node tool/deploy-site.mjs --caddy`: each
on Matt's word.

Elsewhere: listen on 127.0.0.1 and let the web server that holds the certificate pass the site to it (every path:
`/hub`, `/relay/*`, `/files`, `/word`, `/link`, `/market`), with WebSockets and a 10 MiB body allowed. It needs no
other setup; [../docs/SELF_HOSTING.md](../docs/SELF_HOSTING.md) has the samples.
