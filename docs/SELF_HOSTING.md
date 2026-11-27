# Running your own relay

GMFB-25, "Self-hosting the relay, documented", from the gap review against Uplink. Uplink's relay is one
small Dart program with no dependencies beyond Dart's own library (`relay/`). Anyone can run it and point their app at
it in **Settings › Routes › Relay server**. This page covers how to run it, what it needs, and, before you start,
what you give up by moving to it.

## Read this first: what a relay of your own reaches

The app talks to one relay at a time for everything that goes through a relay. Since 2026-11-22 relays can pass
sealed packets to each other, so **friends can be on different relays**. Everything else a relay keeps is still that
relay's own.

Whether a relay talks to others is its keeper's choice, and it is **off unless switched on** (`GHOST_FED`, below).
Two people on two relays reach each other only where both relays have it on and neither blocks the other. Off, a relay
is an island as every relay was before: its people reach only each other through it. **Settings › Routes** says of the
relay in use whether it passes messages to other relays, as that relay says itself.

| | Between people on different relays |
|---|---|
| Friends by username: friend requests, what friends write each other (messages, reactions, edits, read marks), and a group of friends' messages between members who are friends | **Yes**, where both relays talk to each other. Add someone as `@maya@their.relay`; each of you goes on using your own relay, and the two relays pass the sealed packets. Each keeps what is for its own person while they are away. |
| Calls between friends, and a group's voice channel | **Not yet.** A call is a room on one relay. The app says so instead of ringing a friend on another relay. |
| Who is online, away, last seen | Not shown for a friend on another relay. |
| Circles and spaces | **No.** A circle and its spaces are rooms on the relay they were made on, and everyone in them has to use that relay. A link made on a relay of your own names it at its end (`…@relay.example.com`): opened by someone whose app uses another relay, the app says which relay the circle is on and joins nothing, where it used to join the same rooms on its own relay, alone, and say nothing. A browser guest opening a space's link at gogho.st/join is connected to the relay the link names. A link made on gogho.st names none, as before. |
| Your username | Kept on each relay apart. `@maya` is a name on the relay you use; `@maya@relay.example` is the `maya` on that relay, and can be someone else than `@maya` on yours. A name is looked up on the relay it names: by your relay where the two talk, by the app itself where they don't. When the app moves to another relay your username is settled there: claimed there too where it is free; none where someone else holds it (your profile says so and asks you to choose one for that relay); and the one you had on the relay you left is yours again when you go back. A name you gave up on a relay is never claimed there again by itself. |
| Add-me links (`gogho.st/add/<name>`) | A link made on a relay of your own names it after the key (`gogho.st/add/maya#KEY@relay.example.com`; after the `#`, so no server is told). Whoever opens it on the same relay finds the person there; on another relay the app asks the named relay, as `@maya@relay.example.com`, and the request goes from relay to relay where both talk. A link that names none is someone on gogho.st; opened on a relay of your own it is looked for there first and then on gogho.st. Whichever relay answers, the link's key holds the answer to the person who shared it. |
| Your account (username and password, the sealed backup) | Kept on the relay you made it on. Signing in on a new device works only with that device on the same relay, and on a relay other than gogho.st the sign-in screen says which relay it is asking. An app moved to a relay that doesn't hold its account keeps everything and offers **List this device again**, which puts the account on that relay from the device (an Android phone used to forget the account instead). |
| Circle invite words (`gogho.st/c/<word>`) | Kept on each relay apart. A word made on your relay works typed into **Join a circle** by people on your relay; the gogho.st/c/ page only knows gogho.st's words. |
| Files spaces | Kept on your relay's disk, for people on your relay. |
| Texts (SMS, including encrypted texts and data texts) | Unchanged: they go over the phone network, not through any relay. |
| The Marketplace (browsing, installing, reporting a plugin or a person) | Always Uplink's, read from gogho.st whatever relay you use. Submitting a plugin needs a username claimed on gogho.st, so it doesn't work from your relay. |
| Verifying your number, linking Discord, X, Telegram | Off unless you set up your own Twilio Verify service and your own apps with those networks (the env file below). |
| Waking a closed iPhone | Not possible: it needs Apple's push key for the app's bundle id, which only the app's publisher holds. An iPhone gets what was held for it the next time the app is opened. |
| Share feedback | Goes to your relay where you set up a Notion board for it. Where you didn't, the app sends it to gogho.st instead, since it is about the app (the browser client can't: it speaks only to the relay it came from). |
| A computer paired to the phone | Messages go through the phone, so through your relay, and the computer's own connection for spaces goes to the relay the phone says it uses (both on a current version; with an older phone it is gogho.st). |
| Souls | Counted by each relay apart, and sent only between people on one relay. The Souls page says whose count it shows. Bug bounties are given on gogho.st. |
| App updates, docs, the website | From gogho.st, as before. |

So a relay of your own still suits a group that moves together (a family, a team: circles, spaces and calls need
everyone on the same relay), and its people can now also be friends with people elsewhere, where both relays allow it.

### How relays talk, and what it asks of you

- **Nobody is taken on anyone's say-so.** Each account signs a small record of where it lives (a *home record*). Your
  relay passes a packet to another relay only because the person it is for signed a record naming that relay, and takes
  one from another relay only for people whose record names that relay. Relays prove their keys to each other over the
  address that was dialled, so a relay in the middle can't pass a hello on; a relay that claims an address is believed
  only once yours has dialled that address and seen the same key there (for an hour: a relay given a new key there is
  seen with it within the hour), and what is for an address goes only over a link yours dialled there itself. A record
  is good for thirty days.
- **Your relay dials out**, to other relays' hubs, at `wss://` on port 443 and nowhere else, and never to an address on
  your server or its own network. It must be reachable at the address you set as `GHOST_PUBLIC_HUB`: other relays dial
  it to check yours is who it says.
- **What it sees more:** which of its people talk to people on which other relay, and when. Still never what.
- **What it keeps more:** its own key (`relay-key.json`: keep it private, and keep it; it is who your relay is to the
  others; readable by the relay's own user alone, mode 600, and on Windows an ordinary file, which you should keep
  where only that user can read it) and the records its people gave it (`homes.json`). With another relay unreachable,
  packets for it wait in memory (at most 16 MB a relay, 32 MB in all, a mailbox's worth for one sender or recipient,
  seven days; a minute or two for an address never once reached).
- **Allowances.** Every limit is held so no one party can use it up for nothing: each of your people may make your
  relay dial eight new relays an hour and send a share of what another relay takes from yours; strangers' hellos share
  thirty a minute, and a relay at an address yours has checked has its own. Limits per linked relay are counted by its
  checked address, so a relay can't get more by making new keys.
- **Moving.** Someone who moves to another relay signs a record with the next count; their app gives it to the relay
  they leave and the one they join, and tells their friends a few at a time. The relay they left tells any relay that
  still sends it their packets where they live now.

The protocol itself, every message of it, is in [relay/README.md](../relay/README.md) ("Other relays").

### Not done yet

- **Rooms across relays**: circles, spaces and calls. A circle stays on the relay it was made on.
- **Who is online** across relays.
- **One relay at a time**: the app can't be in a circle on another relay while it uses yours. An invite to one says
  which relay to use first.
- **An account signing in on another relay than its own** by its username: the account is on the relay it was made on
  until a device that holds it lists itself on the other (List this device again).

## What it serves

One program on one port (8787 unless told otherwise), plain HTTP and WebSockets:

| Path | What |
|---|---|
| `/hub` (WebSocket) | The hub: apps sign in with their key, find each other, pass sealed packets, hold packets for people away (in memory, 96 MB at most), presence, rooms for circles, spaces and calls, usernames, sealed account backups, invites by number, invite words. Other relays link here too, where you have switched that on. |
| `/relay/<channel>` (WebSocket) | A phone and its paired computer when they're on different networks. |
| `/files/...` | Files spaces' sealed files, on disk. |
| `/word/<hash>` | A circle's invite word, for a web page like gogho.st's /c/. |
| `/link/...` | The pages a network sign-in comes back to (only with those networks set up). |
| `/market/...` | A Marketplace. The apps never read yours (above); the sample env file closes it. |
| `/feedback`, `/bounty` | Uplink's own feedback board and bug bounty; off without their variables. |
| `/app/...` | The app in a browser, as plain files, with `--web` (or `GHOST_WEB_DIR`); `/app/clear-site-data` answers `Clear-Site-Data: "storage"` to the page's own asking (`Sec-Fetch-Site: same-origin`) as it signs out, and is a file that isn't there to anything else. None without it. |
| anything else | `Ghost Messaging relay` as plain text: a quick check that it is up. |

It writes only under its data folder (`--data`): pairings, usernames and linked handles, sealed account backups,
Files, invites, invite words, the Marketplace, the relay's own key (`relay-key.json`) and the home records its people
gave it (`homes.json`) where it talks to other relays, and the accounts that sign in bound to it (`hub-v2.json`); those
two are logs of what changed, written whole again now and then off the relay's main thread. Back that folder up if you care about any of it. Nothing it holds can be read without the apps'
keys, but which installs talk to which is visible to whoever runs it, as with any server.

## Running it

You need a server with a domain name pointed at it, ports 80 and 443 open, and a few hundred MB of memory. Every file
mentioned is in `relay/deploy/` (and `relay/Dockerfile`).

### The environment: nothing is required

`relay/deploy/relay.env.example` lists every variable the relay reads, grouped by what each switches on. **None is
required**: with no file at all it runs the hub, pairings, Files and invite words with their defaults. The sample sets
three things, and you should keep them:

- `GHOST_PUBLIC_URL`: your relay's https address (its built-in default is not yours).
- `GHOST_ADMIN_NAMES=` empty (its built-in default is someone else's username).
- `GHOST_MARKET_ON=0` (the apps never read your Marketplace).

Optional groups: talking to other relays (`GHOST_FED`, `GHOST_PUBLIC_HUB` and the rest, below), a TURN server for
calls (`GHOST_TURN_*`), link helpers for the apps' direct links between devices (`GHOST_LINK_HELPERS`: without one they
link only on one network), the app in a browser (`GHOST_WEB_DIR`; and `GHOST_APP_ORIGIN`, the address it is served
from where that is one of its own, whose page may then read the answers to the reports and feedback it sends, and
nothing else), Files limits (`GHOST_FILES_*`, lower `GHOST_FILES_TOTAL` to fit your disk), Twilio Verify for number
checks (`GHOST_TWILIO_*`), network sign-ins (`GHOST_DISCORD_*`, `GHOST_X_*`, `GHOST_TELEGRAM_*`,
`GHOST_GITHUB_TOKEN`). The rest (`GHOST_APNS_*`, `GHOST_NOTION_*`, `GHOST_BOUNTY_KEY`) only Uplink's own relay
can use; leave them empty.

```sh
cp relay/deploy/relay.env.example relay.env   # edit; keep it readable by root (or the relay's user) only
```

### With Docker Compose (relay and Caddy, TLS included)

```sh
cd messaging/relay/deploy
cp relay.env.example relay.env               # and edit
cp Caddyfile.example Caddyfile               # put your domain in place of relay.example.com
docker compose up -d
curl https://relay.example.com/              # Ghost Messaging relay
```

Caddy gets and renews the certificate by itself once your domain's DNS points at the server. The relay isn't
published on any port of its own; only Caddy reaches it. What it keeps is in the `relay-data` volume. Needs Docker
Compose 2.24 or later (for the optional `env_file`).

Compose pulls the image every release publishes for x64 and arm64 (`.github/workflows/relay.yml`):
`ghcr.io/infamousvague/ghost-relay`, tagged with the version and `latest`. The image alone, without Compose:

```sh
docker run -d --name ghost-relay --restart unless-stopped -p 127.0.0.1:8787:8787 \
  -v ghost-relay-data:/data --env-file relay.env ghcr.io/infamousvague/ghost-relay:latest
```

Built yourself instead: `docker build -t ghost-relay messaging/relay`, and `ghost-relay` in place of the published name.

It runs as an unprivileged user in an image with nothing but the program, the C library and certificates.

### With systemd (no containers)

Each release publishes the program for Linux on x64 and arm64, with `deploy/` beside it, as `relay-<version>` on the
public repository's releases page. Download, check and install it (or build it yourself with Dart 3.11 or later:
`dart compile exe bin/relay.dart -o ghost-relay` in `messaging/relay`), then follow the steps at the top of
`deploy/ghost-relay.service`:

```sh
V=0.12.42 A=x64   # or arm64
curl -LO https://github.com/InfamousVague/ghost-messaging/releases/download/relay-$V/ghost-relay-$V-linux-$A.tar.gz
curl -LO https://github.com/InfamousVague/ghost-messaging/releases/download/relay-$V/ghost-relay-$V-linux-$A.tar.gz.sha256
sha256sum -c ghost-relay-$V-linux-$A.tar.gz.sha256 && tar xzf ghost-relay-$V-linux-$A.tar.gz && cd ghost-relay-$V-linux-$A
sudo useradd --system --no-create-home --shell /usr/sbin/nologin ghost-relay
sudo install -d -m 755 /opt/ghost-relay && sudo install -m 755 ghost-relay /opt/ghost-relay/ghost-relay
sudo install -d -o ghost-relay -g ghost-relay -m 700 /var/lib/ghost-relay
sudo install -o root -g ghost-relay -m 640 relay.env /etc/ghost-relay.env
sudo cp deploy/ghost-relay.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now ghost-relay
```

It listens on `127.0.0.1:8787` only, writes only to `/var/lib/ghost-relay`, and restarts if it stops. Then put a web
server in front of it for TLS:

- **Caddy**: `relay/deploy/Caddyfile.example`, with `relay:8787` changed to `127.0.0.1:8787`.
- **nginx**: `relay/deploy/nginx.conf.example` (WebSocket upgrade headers, a 10 MB body limit, long read timeouts,
  no buffering), with a certificate from certbot or similar.

Whichever you use, it must pass WebSockets on, let a 10 MiB request body through (Files' pieces are up to 8 MiB),
and not cut an open WebSocket off after a minute.

To update: download the newer release (or build again), `sudo install -m 755 ghost-relay /opt/ghost-relay/ghost-relay`, `sudo systemctl restart
ghost-relay`. A restart drops whoever is connected (the apps reconnect by themselves) and loses held packets and
presence, which are only in memory.

### Talking to other relays (optional)

Off unless you switch it on. To let your people be friends with people on other relays, set two things in the env
file and restart the relay:

```sh
GHOST_FED=open                                 # or: list, with GHOST_FED_ALLOW=relay.example.org,another.example.net
GHOST_PUBLIC_HUB=wss://relay.example.com/hub   # your relay's own hub address, as the world reaches it
```

- `open` links with any relay that proves its key; `list` only with the hosts (or relays' names) in
  `GHOST_FED_ALLOW`. `GHOST_FED_BLOCK` names relays never linked with, in either mode.
- The other relay has to have it on too, and not block yours. Friendship across relays takes both.
- Your relay must be reachable at `GHOST_PUBLIC_HUB` from outside (other relays dial it to check your relay's key),
  and be able to dial out on port 443.
- It says its own name as it starts (`other relays: open, this one is 3f9c…`): that name is what another relay's
  keeper puts in their list to name yours.
- Limits per linked relay have defaults you can change: `GHOST_FED_PACKETS_A_MINUTE`, `GHOST_FED_BYTES_A_DAY`,
  `GHOST_FED_LOOKUPS_AN_HOUR`. Of them, each install has a share, each address its installs come from twice that, and
  installs new to your relay half of each together: people who have held a username on it, or used it, for two days
  always have the rest, however many installs someone else makes. Keep Caddy or nginx beside the relay so it sees each
  person's own address.
- A relay with no address of its own (behind a home router) can set `GHOST_FED_VIA` to a public relay it dials and
  stays linked to, in place of `GHOST_PUBLIC_HUB`: its people are then reached through that relay, where that relay
  lets relays stay. Letting relays with no address stay linked to yours (and passing their people's packets on under
  your relay's name) is a setting of its own, off unless you set `GHOST_FED_STANDING=open` or name the relays.
- Off (the default) your relay does nothing of this at all: it makes no key, keeps no records, and its hello says
  nothing of other relays.

Check it: the hub's greeting names your relay and says it talks (`"relay": {"id": …, "url": …, "fed": true}`), and
**Settings › Routes** in the app shows "Passes messages to other relays".

### Sign-ins bound to your relay (recommended)

List every host name your relay is reached at, commas between, with a port where it is not 443:

```sh
GHOST_HUB_NAMES=relay.example.com,www.relay.example.com
```

With them the hub asks apps to sign in bound to the name they dialled, and refuses a sign-in made for another relay;
once an account has signed in so, it takes no other kind from it. That stops a relay one of your people was pointed at,
or asked a name of, from signing in to yours as them. An app that dialled a name you didn't list is refused, so list
them all, without ports where it is 443; without the setting, sign-ins are taken as they always were, and the keys kept
are not held to. On Windows and elsewhere the names it has seen sign in so are kept in `hub-v2.json` in the data folder:
200,000 at most, those that have held a username for two days going last, at most 30 new ones an hour from one address
(an IPv6 address counts by its first 48 bits) and 5,000 from all. Switch it on only once your people's apps (and the
browser extension) sign in v2: from an account's first v2 sign-in on, its older builds are refused and told to update.
Keep every listed name registered to you for as long as it is listed. The address is the one your
proxy saw where the proxy is on the same machine or a private network (it reads the last `X-Forwarded-For` it adds),
else the connection's own: keep Caddy or nginx beside the relay, as the examples do, so each person counts as
themselves.

### How much the relay holds

What every connection holds together (a message half come in, what waits for a peer to read) is counted against one
budget, 64 MB unless you set `GHOST_WIRE_MB`. A connection is ended for it only when more than 8 MB waits for it
(`GHOST_WIRE_EACH_MB`) for 10 seconds (`GHOST_WIRE_STALL_S`), or a message coming in hasn't grown for 20 seconds
(`GHOST_WIRE_IN_STALL_S`); past the budget together, those stalled longest go first, then those holding the most. One
whose own answers pile up is not read from until they go. The hub hands over what it keeps (a room's messages, what was
held for someone) only as fast as each device takes it. With the 96 MB kept for people who are away, that keeps the
relay inside a few hundred megabytes however many connect; give it more where your machine has more.

### Calls through your own TURN server (optional)

Calls go straight between the two devices where they can. Where they can't (two strict NATs, some mobile networks),
they need a TURN server to relay through. Without one on your relay such calls don't connect.

1. Install coturn (`apt install coturn`, or `docker compose --profile calls up -d` with the compose file).
2. Copy `relay/deploy/turnserver.conf.example` to `/etc/turnserver.conf` (or `deploy/turnserver.conf` for Compose)
   and fill in the secret (`openssl rand -hex 32`), your domain as the realm, and your public address. If clients may
   relay to each other through this same machine, allow its own public address with `allowed-peer-ip`.
3. Open UDP and TCP 3478, and UDP 49160 to 49200.
4. In the relay's env file set `GHOST_TURN_SECRET` to the same secret and `GHOST_TURN_URLS` to
   `turn:relay.example.com:3478?transport=udp,turn:relay.example.com:3478?transport=tcp`, and restart the relay.
   It then hands each call short-lived credentials made with that secret.

### A link helper for direct links (optional)

The apps also make direct links between a person's own devices and their friends' devices (`OPEN_NETWORK.md`, section
2): a second way through beside the relay, and how an app checks what the relay tells it. Two devices on one network
link by themselves. Across networks they need a **link helper**: a server both can reach, which tells each the address
the internet sees it at, passes their first packets, and carries their traffic for as long as no straight path can be
made. It is iroh's relay server, `iroh-relay`. It is not the Uplink relay, and the two know nothing of each
other.

iroh's makers run public ones, for "development and hobby use only", so the app ships with none: it uses the ones its
relay names, and with none named its devices link only on one network. A link helper sees which device ids link, from
which addresses, and how much they send. It never sees an account's name or what is said: the traffic is sealed
between the two devices.

1. **Build it.** `tool/build-link.sh host` on the server itself (Rust 1.91 or later) gives
   `build/link/host/iroh-relay`. From another machine with zig and cargo-zigbuild, `tool/build-link.sh` gives
   `build/link/iroh-relay` for Linux on x86-64 (glibc 2.31 or later: Ubuntu 20.04, Debian 11, and newer). Either way
   it is `iroh-relay` 1.5.0's source as crates.io holds it, taken by its checksum and built with the lock file its
   authors published. Nothing prebuilt is fetched.
2. **Its settings.** Copy `relay/deploy/link-helper.toml.example` to `/etc/ghost-link/config.toml` and put your
   relay's name in it. Each line says why it is there. As written the helper shares a machine with the web server
   that has ports 80 and 443, so it takes a port of its own and apps reach it at `https://relay.example.com:7843`.
   The server passes over a setting it does not know without a word: copy the names, don't retype them.
3. **A certificate** for that name, as two PEM files where the settings say
   (`/etc/ghost-link/certs/relay.example.com.crt` and `.key`, readable by the helper's user). The web server already
   has one. Caddy keeps it in `/var/lib/caddy/.local/share/caddy/certificates/<issuer>/<name>/` (with the Compose
   file, under `/data/caddy/certificates/` in the `caddy-data` volume); certbot in `/etc/letsencrypt/live/<name>/`
   (`fullchain.pem` and `privkey.pem`). Copy the pair, and copy it again whenever it is renewed, each file by
   renaming a finished copy over the old one: the helper reads the two files again once a day, so nothing needs
   restarting. `node tool/deploy-link.mjs --print` shows the few lines of shell and the daily timer that do it on
   our own server.
4. **The service.** `relay/deploy/ghost-link.service`, with the steps at its top: a user of its own with no shell,
   nothing writable but its own folder, 300 MB and one processor at most.
5. **Ports.** Open TCP 7843 (where apps reach it) and UDP 7842 (where it tells a device its address; keep that
   number, apps look for it there). 7844 and 7845 are for the machine itself and stay closed.
6. **Tell the relay.** In the relay's env file, `GHOST_LINK_HELPERS=https://relay.example.com:7843`, and restart the
   relay. Its hub hands the address to each app as it signs in.

Then check it:

```sh
curl https://relay.example.com:7843/healthz          # {"status":"ok","version":"1.5.0","git_hash":"unknown"}
cd messaging/native/link-check
cargo run -- https://relay.example.com:7843          # two devices sign in, link through it and straight; exits 0
cargo run                                            # the same against one started on this machine (needs `build-link.sh host`)
curl -s http://127.0.0.1:7845/metrics                # on the server: what it has carried, and for how many devices
```

What to know before relying on it:

- **Anyone who knows the address can link through it**, Uplink or not: the apps' device ids are known to no
  server, so there is no list to hold a caller to. What bounds it is the limit in the settings (one device may send
  256 KiB a second through it, after a first megabyte) and the service's memory and processor. A device that sends
  more than that is slowed, not cut off, and whatever else it is sending through the helper waits behind the load
  while it lasts. The server can ask for a token instead (`access.shared_token`); the apps have no way to be handed
  one yet.
- **A network that lets nothing out but ports 80 and 443** cannot reach a helper on 7843. Devices there link only
  where they can reach each other's addresses as they are; the relay carries everything else, as it always did.
- **A name of its own instead.** Where the helper can have a name whose ports 80 and 443 are its own (another
  address, or a machine with no web server), it can get its own certificate: in the settings,
  `http_bind_addr = "[::]:80"`, and under `[tls]` `https_bind_addr = "[::]:443"`, `cert_mode = "LetsEncrypt"`,
  `hostname`, `contact` and `cert_dir = "/var/lib/ghost-link"`; in the service,
  `AmbientCapabilities=CAP_NET_BIND_SERVICE`. Apps then reach it at `https://link.example.com`. We don't run ours
  that way: this much is read from `iroh-relay`'s source, not from use.
- **Updating** is building again, installing the program over the old one and `sudo systemctl restart ghost-link`.
  A restart drops every device signed in to it at that moment; each signs in again by itself.

## Pointing the app at it

On each phone: **Settings › Routes › Relay server**. Type your relay's address (`relay.example.com` is enough; it
becomes `wss://relay.example.com/hub`) and press **Check it and use it**. The app connects and waits for the hub's
greeting; if an Uplink relay doesn't answer, nothing changes and it says why. If one does, it says what moving
means (above) and switches only when you say so. The section always shows which relay is in use, and on your own a
**Go back to Uplink's relay** row switches back in one press.

Everyone you want in a circle, a space or a call with has to set the same address. A friend can also be on another
relay, where yours and theirs talk to each other (above): add them as `@name@their.relay`.

## Checking it

```sh
curl https://relay.example.com/                 # Ghost Messaging relay
curl https://relay.example.com/market           # {"ok":true,"open":false,...} with GHOST_MARKET_ON=0
journalctl -u ghost-relay -f                    # or: docker compose logs -f relay
```

The program says on start what it has: pairings and handles kept, Files spaces, whether a TURN server is set, and
which sign-ins are on. `dart test` in `relay/` includes `test/self_host_test.dart`, which starts the program with an
empty environment and checks the sample env file lists every variable the relay reads.
