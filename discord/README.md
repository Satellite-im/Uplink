# Uplink's Discord bot: presence and the voice bridge

Lets the app show a linked Discord server's voice channels as **spaces**, with who is in each, and, when an Uplink user
presses one, **bridges** it: the bot joins that Discord voice channel and the matching Uplink space at once, and
carries the sound and the channel's text chat both ways. Uplink people talk through the bot ("Uplink · Matt"); Discord
people are heard in the space and listed in it. One Node program (discord.js 14.27.0, @discordjs/voice 0.19.2) holding
one gateway connection to Discord, one connection to Uplink's relay hub on the same box, and answering the app over
HTTP on `127.0.0.1:18788`. On the box the web server passes `https://ghost-sms.com/discord/*` (and
`https://gogho.st/discord/*`) to it with the `/discord` prefix kept.

This is a separate bot from Ghost.md's Discord notetaker (`discord/bot` at the repository root, service
`glyph-discord`), which records calls. They share nothing.

```sh
npm ci                      # discord.js and what it needs
npm test                    # node --test: codes, tokens, state, routes, the bridge (no Discord or relay needed)
DISCORD_TOKEN=… DISCORD_APP_ID=… npm start   # a real bot; logs the invite link
```

## How linking works

1. Someone with **Manage Server** runs `/ghost link` in the Discord server. The bot answers only them
   (ephemeral): *"Your code is ABC123. In Uplink tap New › Add a Discord server and enter it. It works
   once, for 10 minutes."*
2. The app sends the code to `POST /discord/claim` and gets back a token for that server.
3. The app asks `GET /discord/state?token=…` whenever it wants the server's voice channels and who is in them.
4. `/ghost unlink` (Manage Server) revokes every token for the server. `/ghost status` says how many links it has.

Discord sets permissions per command, not per subcommand, so all of `/ghost` is Manage Server by default
(`default_member_permissions` = ManageGuild); a server can open it to more people under Server Settings ›
Integrations, and `link`/`unlink` still check Manage Server themselves.

## The contract

All answers are JSON, with `Access-Control-Allow-Origin: *` (GET, POST and OPTIONS preflights from any origin) and
`Cache-Control: no-store`. Request bodies are capped at 4 KB (`413 {"error":"too large"}`). Every route also answers
without the `/discord` prefix (`/claim`, `/state`, `/invite`).

**`POST /discord/claim`** with `{"code":"ABC123"}`

- `200 {"token":"<32 lowercase hex>","guild":{"id":"…","name":"…","icon":"https://cdn.discordapp.com/icons/<id>/<hash>.png" | null}}`
- `404 {"error":"unknown code"}` for an unknown, expired or already-used code. A code works once, for 10 minutes;
  case and surrounding spaces don't matter. Each claim makes a new token.
- `429 {"error":"slow down"}` (with `Retry-After`) past 10 attempts a minute from one address, or 300 a minute
  overall, so codes can't be guessed. The address is the last `X-Forwarded-For` entry when the request comes from
  loopback (Caddy), else the socket's.
- `410 {"error":"gone"}` if the code was right but the bot has since left that server; `400 {"error":"bad json"}`.

**`GET /discord/state?token=<token>`**

```json
{
  "guild": { "id": "…", "name": "…", "icon": "https://cdn.discordapp.com/icons/…/….png" },
  "channels": [
    {
      "id": "…", "name": "Lounge", "kind": "voice", "position": 0,
      "members": [
        { "id": "…", "name": "Casper", "avatar": "https://cdn.discordapp.com/avatars/…/….png",
          "muted": false, "deafened": true, "video": false, "streaming": false, "bot": false }
      ]
    },
    { "id": "…", "name": "Talks", "kind": "stage", "position": 1, "members": [] }
  ],
  "at": 1763251200000
}
```

- Every voice (`"voice"`) and stage (`"stage"`) channel the bot can see, empty ones included, in Discord's sidebar
  order: channels outside a category first, then each category in its order, and by position within. `position` is
  the channel's index in that order (0, 1, 2, …).
- Members within a channel are sorted by name. `name` is their nickname on the server, else their display name,
  else their username. `avatar` is their server avatar, else their own, else `null`. `muted` and `deafened` are
  true for self or server mute/deafen. A voice state without a cached member is fetched over REST first (no
  privileged intent needed); one that still can't be found shows as `"Unknown"`.
- `401 {"error":"not linked"}` for an unknown or revoked token; `410 {"error":"gone"}` when the bot has been removed
  from the server (the links are kept, so they work again if it's added back); `503 {"error":"starting"}` while the
  bot is still connecting to Discord, or Discord reports the server unavailable.

Each channel the bridge is in now also has `"bridged": true` (the key is absent otherwise).

**`POST /discord/voice/join`** with `{"token":"<link token>","channel":"<voice channel id>"}`

- `200 {"seed":"<64 lowercase hex>","name":"Lounge","guild":"<id>","channel":"<id>","bridge":"<32 hex>"}`. By the
  time it answers, the bot is in the Discord voice channel and the bridge is in the Uplink space made from `seed`
  (asking again changes nothing, and restarts the 30-second leave clock below). The app joins that space like any
  other (a `VoiceChannel` with this seed and name, no owner or roles); `bridge` is the bridge's hub id, so the app
  can tell which member is Discord.
- The seed is 32 random bytes made the first time a channel is asked for and kept in `bridges.json` (below): never
  derived from public ids, so only someone whose app holds a link to that server can reach the space.
- `401 {"error":"not linked"}` for a token that is not linked; `404 {"error":"unknown channel"}` for an id that is not
  a voice channel of the token's server (stage channels are not bridged); `410 {"error":"gone"}` when the bot has
  left the server; `403 {"error":"no permission","missing":["View Channel","Connect","Speak"]}` (those it lacks in
  that channel); `409 {"error":"full"}` when the channel is at its user limit; `409 {"error":"busy"}` when the bot is
  already bridging another channel of that server with Uplink people in it (a bot can be in one voice channel per
  server; an idle bridge gives way); `502 {"error":"voice failed"}` when Discord voice did not connect within 20 s;
  `503 {"error":"relay unreachable"}` when the hub did not let the bridge in within 10 s; `503 {"error":"starting"}`
  while the bot connects (or with `GHOST_BRIDGE=off`); `429` past 30 a minute from one address; `400 {"error":"bad json"}`.

**`GET /discord/invite`** → `200 {"url":"https://discord.com/oauth2/authorize?client_id=<APP_ID>&scope=bot%20applications.commands&permissions=640748544"}`.
No token needed; the app shows it as "Add the bot to your server". `640748544` is worked out in `src/http.js` from named
flags: View Channel (1024), Send Messages (2048), Read Message History (65536), Connect (1048576), Speak (2097152),
Use Voice Activity (33554432), Change Nickname (67108864), Manage Webhooks (536870912).

**`GET /discord/`** → `200 {"ok":true,"service":"ghost-discord"}` (the deploy's health check).

## The bridge

What it does once a join request has put it in both places:

- **In the Uplink space** it is one member, speaking the app's protocol (`lib/voice/voice.dart`, `lib/voice/hangout.dart`,
  `site/join/voice.js`): it answers each newcomer's WebRTC offer (and offers itself to anyone already there when it
  comes in), says `{t:'me', n:'Discord', m:false, v:false}`, and, sealed in the call's room like everything else,
  `{t:'dc', people:[{id, name, avatar, speaking, muted, deafened, bot}]}`: everyone in the Discord voice channel but the
  bot, by name. It is said when the bridge comes in, to each newcomer, whenever someone comes, goes, mutes or starts or
  stops speaking (Discord's speaking events), and at least every 5 s.
- **Sound, Uplink → Discord**: every Uplink member's track is decoded, mixed, and played into the Discord channel as
  one stream. It is sent only while someone is actually talking (a level gate with 300 ms of hang, since apps send
  packets even in silence), followed by five frames of Opus silence and Discord's "stopped speaking", so the bot's
  green ring means an Uplink person is talking.
- **Sound, Discord → Uplink**: each Discord speaker's stream from the receiver (already out of Discord's DAVE
  end-to-end encryption) is decoded, mixed, and sent to each Uplink member on the bridge's one outgoing track. Each
  member gets their own mix with every other Uplink member in it and their own voice taken out, so nobody hears
  themselves back. Everything is 48 kHz stereo in 20 ms frames, with a small queue per speaker (40 ms to start, at
  most 120 ms) to even out arrival.
- **Nickname**: "Uplink · Matt" while one Uplink person is in the call, "Uplink · 3 people" for more, and back to the
  bot's own name when nobody is (changed at most every 1.5 s; skipped quietly without Change Nickname).
- **Chat**: the voice channel's own text chat (Discord's "text in voice") and the space's chat. A Discord message
  (not the bot's, not from the bridge's webhook or any webhook of this application, not a system message) goes into
  the space as a message from the bridge with `n` set to the author's server name; attachments become their links.
  An Uplink message goes to Discord through a webhook named "Uplink" that the bot makes once in that channel
  (its id and token kept in `bridges.json`), posted under the sender's name with all mentions disabled (nobody is
  pinged by `@everyone` from Uplink). Without Manage Webhooks it is posted by the bot as `**Name:** text`. Nothing the
  bridge said itself is passed back, and history a newcomer is sent is never re-posted. The bridge keeps the space's
  last 300 messages in memory (never on disk) so it can answer a newcomer's history request like any member.
- **Leaving**: when no Uplink member has been in the call for 30 s, it leaves the Discord channel and the space. If
  Discord disconnects it, it waits 5 s for Discord's own reconnect, then rejoins once; if that fails (or it is
  dropped again), it leaves the space. Moved to another channel by someone, it leaves (it would carry the wrong
  channel).

### Privacy

A bridged space is **not end-to-end encrypted on the Uplink side**: the bridge holds the space's key and hears, mixes
and re-encodes everything said in it, as it must to carry it to Discord. Discord's side is DAVE-encrypted between
Discord clients and the bot, and the bot decrypts it for the same reason. The relay still sees only sealed packets.
Anyone who can read the box's `/var/lib/ghost-discord/bridges.json` can join every bridged space; it is readable by
the service's user only. The bridge never records anything: sound passes through memory 20 ms at a time.

### Packages

- **@discordjs/voice 0.19.2** (the current release; requires Node ≥ 22.12, which matches discord.js 14.27): joins
  voice, receives each speaker's Opus, and sends ours with `playOpusPacket`. Discord now requires its **DAVE**
  end-to-end encryption for voice; this version speaks it (on by default) through **@snazzah/davey 0.1.12** (pulled in
  by it, a Rust library with prebuilt binaries per platform, linux-x64-gnu among them). Transport encryption is
  AES-256-GCM through Node's own crypto, so no sodium library is needed.
- **@evan/opus 1.0.3** for Opus: libopus with prebuilt binaries in the package and the same libopus as WebAssembly
  when none fits; no compiler, no install script. Not opusscript: its WebAssembly build aborted
  (`opus_decoder.c: assertion failed`) with as few as seven coders alive at once, and the bridge keeps one per speaker
  and one per member. Not @discordjs/opus: it downloads a binary at install time or compiles one.
- **werift 0.27.0** for WebRTC with the apps: WebRTC written in TypeScript (ICE, DTLS, SRTP in JavaScript), so no
  native code. Audio only: a picture an app offers is refused in the answer (port 0), which apps handle.

### Resources

Every 20 ms the bridge decodes every speaker, encodes once for Discord and once for each Uplink member, and werift
runs DTLS and SRTP in JavaScript. On an Apple-silicon Mac the loopback test (bridge plus a stand-in app in one
process, both WebRTC ends) used about a fifth of a core and 95 MB; the box is slower and a call may have several
members. Hence the service's limits are 400 MB (`MemoryMax`, Node's heap at 256 MB) and one whole processor
(`CPUQuota=100%`), up from 200 MB and half.

### The network

The apps reach the bridge over UDP (WebRTC, STUN through Google's servers as the apps use). The box has a public
address, so ICE normally connects even from behind a home router: the bridge's own checks open the way back through
a stateful firewall. If the box's firewall drops inbound UDP that the bridge did not start (or an app is behind a
symmetric NAT), set `GHOST_RTC_PORTS=40000-40100` (any range) in `/etc/ghost-discord/env` and allow that range in;
the deploy notes it when `ufw` is active. There is no TURN server.

## What it keeps

- **Links**: `links.json` in `DISCORD_DATA`, holding the server id and the SHA-256 of each token, never the token
  itself. Written to a temporary file and renamed over the old one. Tokens are checked by comparing the hash against
  every stored hash in constant time.
- **Codes**: in memory only. A restart forgets codes not yet used (run `/ghost link` again). At most five waiting
  per server.
- **Bridges**: `bridges.json` in `DISCORD_DATA`: the bridge's own key (PKCS#8, so its hub id stays the same), each
  bridged channel's seed, and each channel's webhook id and token. Mode 0600 in a 0700 folder, written the same way.
- **Logs**: outcomes, server and channel ids and counts. Never a token, a code, a seed, a key, a message or a name.

## Environment

| Name             | What                                                                 |
| ---------------- | -------------------------------------------------------------------- |
| `DISCORD_TOKEN`  | The bot's token (required).                                          |
| `DISCORD_APP_ID` | The application's id (required: the invite link and the commands).   |
| `PORT`           | Default `18788`. It always listens on `127.0.0.1` only.              |
| `DISCORD_DATA`   | Where `links.json` and `bridges.json` live. Default `./data` (on the box: `/var/lib/ghost-discord`). |
| `GHOST_HUB`      | The relay's hub. Default `ws://127.0.0.1:18787/hub` (the relay on the same box; the unit sets it). |
| `GHOST_BRIDGE`   | `off` runs the presence bot alone (`/voice/join` answers 503). Default on.  |
| `GHOST_RTC_PORTS`| Optional `min-max`: the UDP ports WebRTC uses towards the apps, for a firewall rule. |

Intents: `Guilds` and `GuildVoiceStates`, plus `GuildMessages` and the privileged `MessageContent` for the chat. If
Discord refuses Message Content at login (it is off in the Developer Portal), the bot says so once in its log,
connects again without the two, and runs without the chat bridge; voice is unaffected.

`/ghost` is registered globally each time the bot starts. Global commands can take a little while to show up in a
server the first time.

## Code layout

- `src/bot.js` and `src/voice.js`: the only files that import discord.js (and @discordjs/voice). The client, the
  commands, the adapter that hands servers to the HTTP side, and the Discord half of the bridge (joining voice, the
  receiver, playback, nickname, webhook).
- `src/bridge/`: everything else of the bridge, testable without Discord or a network. `bridge.js` (the bridges,
  the leave rule, who says what when), `space.js` (the bridge as a member of an Uplink space), `hub.js` (the hub
  connection and key), `protocol.js` (seeds to rooms and keys, sealing, frames: a port of `site/join/voice.js`),
  `rtc.js` (werift), `audio.js` and `mixer.js` (the 20 ms engine and mixing), `opus.js`, `mapping.js` (the `dc` list,
  the nickname, chat each way), `store.js` (`bridges.json`).
- `src/http.js`: the routes, CORS, the body cap, the rate limits.
- `src/state.js`: builds the `/state` JSON from a guild-like object (the fields of discord.js's `Guild` it reads are
  listed at the top).
- `src/codes.js`, `src/store.js`, `src/ratelimit.js`, `src/commands.js`: link codes, tokens, limits, and what
  `/ghost` answers.
- `test/`: `node --test` with fake guild, channel and member objects, an in-process stand-in for the relay's hub
  (`fakehub.js`, checking the sign-in signature as `relay/lib/hub.dart` does), and the browser join page's own
  `Hangout` and `Chat` from `site/join/voice.js` on the other side of the space. `loopback.test.js` runs the whole
  bridge with real WebRTC and Opus against a stand-in app: Discord must hear the app's tone, the app Discord's and
  never its own.

## On the box

`node tool/deploy-discord.mjs` (from `messaging/`) installs it as the `ghost-discord` user (no shell), with its own
Node 22 in `/opt/ghost-discord/node`, the program in `/opt/ghost-discord/app`, links and bridges in
`/var/lib/ghost-discord`, and the token in `/etc/ghost-discord/env` (root only). The systemd service `ghost-discord`
restarts it if it stops, can write nowhere else, and is capped at 400 MB and one CPU. `tool/deploy-site.mjs --caddy`
passes `/discord/*` to it.

Dependencies are installed on the Mac **for the box**: `npm ci --omit=dev --ignore-scripts --os=linux --cpu=x64
--libc=glibc` (npm 10.9 or newer), which fetches the linux-x64 builds of @snazzah/davey and keeps @evan/opus's
prebuilds; the deploy refuses any other native file, and on the box it loads @discordjs/voice, DAVE, Opus (encoding
and decoding a frame) and werift with the box's Node before anything is changed.

## Matt's one-time setup

1. Create an application at <https://discord.com/developers/applications>, open **Bot**, and press **Reset Token**
   to copy its token. Copy the **Application ID** from **General Information**. On the same Bot page, under
   **Privileged Gateway Intents**, switch on **Message Content Intent** (for the chat bridge; Presence and Server
   Members stay off). Without it the bot still runs and bridges voice, and says in its log that chat is off.
2. Put both in a file on the Mac, for example `~/.config/mattssoftware/ghost-discord.env`:

   ```
   DISCORD_TOKEN=...
   DISCORD_APP_ID=...
   ```

   Then, from `messaging/`, run:

   ```sh
   node tool/deploy-discord.mjs --env ~/.config/mattssoftware/ghost-discord.env --glyph ~/Development/Apps/glyph --keep-connection \
     && node tool/deploy-site.mjs --caddy --glyph ~/Development/Apps/glyph
   ```

   The token goes to the box on the ssh session's stdin, never in a command line or a chat. The second command tells
   the web server about `/discord/*`; it's needed only once. Run both from a checkout where this folder is merged with
   the latest site, because `deploy-site.mjs` also ships `site/` from whatever checkout it runs in. Later deploys are just `node tool/deploy-discord.mjs`
   (the values on the box are kept).
3. Open the invite link to add the bot to a server. The deploy prints it, the service logs it, and
   `https://ghost-sms.com/discord/invite` returns it. The template is
   `https://discord.com/oauth2/authorize?client_id=<APP_ID>&scope=bot%20applications.commands&permissions=640748544`.
   Then run `/ghost link` in that server and enter the code in the app.

### Upgrading from the presence bot (once)

1. Developer Portal › your application › **Bot** › Privileged Gateway Intents › switch on **Message Content Intent**,
   and save.
2. Deploy (`node tool/deploy-discord.mjs`; the values on the box are kept).
3. **Re-invite the bot** to each server with the new link (`https://ghost-sms.com/discord/invite`): the old invite
   granted View Channels only, and opening the new link on a server the bot is already in updates its role's
   permissions (Connect, Speak, Use Voice Activity, Send Messages, Read Message History, Change Nickname, Manage
   Webhooks). Links stay valid; nobody needs `/ghost link` again. A channel that denies the bot Connect or Speak by an
   override answers `403` with what is missing.
