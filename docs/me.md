# Me, and friends joining

Matt, 2026-11-14: "Add a 'me' section to settings and allow linking popular social like telegram, discord, x, etc to
be notified when one of your friends or followers joins ghost messaging". Asked how, he chose: a watch list plus the
networks whose follow lists are open; proof by signing in with each network; and nothing kept on the server unless
the person opts in.

| Part | Where | What |
| --- | --- | --- |
| The server's keeper of handles | `relay/lib/handles.dart` (`relay/test/handles_test.dart`) | Links, listing, watch lists, the sign-in pages under `/link/`, reading public profiles |
| The texting service | `relay/lib/texts.dart` | `TextCodes`: something that texts a number a code and says whether a code is the one it sent. Twilio Verify is the one behind it |
| Its place in the relay | `relay/lib/hub.dart`, `relay.dart`, `bin/relay.dart` | A connection's `{"dir": …}` messages go to it; `/link/*` is its pages; its settings come from the environment |
| The phone's half | `lib/me/me.dart` (`test/me_test.dart`: two installs and the real relay) | What is linked, watched and joined, kept on the phone; the conversation with the server |
| The screens | `lib/ui/me.dart` (`test/number_screen_test.dart` for the number's page) | Settings › Me, Settings › Friends joining, linking by code, verifying the number, adding handles |

## What it does

- **Settings › Me**: your number, **Verified** once a code texted to it has come back (below), and your key;
  **Linked accounts** (Discord, Telegram, X, Bluesky, Mastodon, GitHub);
  **Tell friends I'm here**, off until switched on; **Remove everything about me**.
- **Settings › Friends joining**: who of the people you watch for is on Uplink, the newest first and marked
  New until the page is opened; **Add handles**; **Bring in who I follow** for a linked Bluesky, Mastodon or GitHub
  account; the list by network, each handle taken off by a press. The Settings ring on the navigation pill wears the
  number of new ones.

## Why a watch list

Discord, Telegram and X do not let an app read someone's friends or followers (X sells it; Discord and Telegram do
not offer it at all). So nothing can say "your Discord friends" by itself. What works on every network is the other
way round: you say which handles you care about, and you are told when one of them proves the account is theirs and
chooses to be found. Bluesky, Mastodon and GitHub publish who an account follows, so for those the list fills itself.

## Proving an account

A handle is never typed and believed: someone could say they are anyone.

| Network | How | Needs on the server |
| --- | --- | --- |
| Discord | Sign in with Discord (OAuth 2, scope `identify`): the server asks Discord who signed in | `GHOST_DISCORD_ID`, `GHOST_DISCORD_SECRET` |
| X | Sign in with X (OAuth 2 with PKCE, scopes `users.read tweet.read`) | `GHOST_X_ID`, and `GHOST_X_SECRET` if the app is a confidential client |
| Telegram | Telegram's login widget, which signs who it is with our bot's token | `GHOST_TELEGRAM_BOT` (the bot's username, no @), `GHOST_TELEGRAM_TOKEN` |
| Bluesky, Mastodon, GitHub | A code the server makes up (`ghost-` and ten hex digits), put in the account's public profile and read back through the network's public API | Nothing. `GHOST_GITHUB_TOKEN` is optional and lets the server read GitHub more often |

A network whose values are not set is **off**: its row in Settings › Me says signing in is not set up on the relay
server yet, and everything else works. So this can go out with none of the three set, and each is switched on by
adding its values and restarting the relay.

## A phone number

Matt, 2026-11-14: "is there any free service we can setup to verify phone numbers with a text code that gets sent to
the app to link the phone number in the 'me' section", and then, told there is no good free one: "I'd like to use a
third party service that allows us to send the text code to a number to verify so it can't be spoofed".

A number is the one thing here a phone could simply say of itself, and a phone can say anything. So it is proved the
way a bank proves it: a code is texted **to the number**, and only a phone that receives that number's texts can
say it back.

1. Settings › Me › **Number** says "Not verified" and opens a page with the phone's own number filled in.
   **Text me a code** asks the relay server (`{"dir": "text", "p": "phone", "handle": "+15550100199"}`).
2. The relay asks the texting service to text that number. The service makes the code, sends it, and remembers it.
   The relay never sees the code it did not get back from the app, and keeps none.
3. The text arrives ("Your Uplink verification code is: 482913"). The page reads the code out of it and
   sends it back (`{"dir": "code", …, "code": "482913"}`) with nothing pressed; it can be typed too.
4. The relay asks the service whether that is the code. Where it is, the number is linked to this install like any
   account (`{"dir": "linked", "p": "phone", …}`), and the row says **Verified**.

What holds it to that:

- **Only the install a code was sent for may try it**, and for ten minutes. Someone who knows your number and
  guesses at a code while you verify is refused before the service is asked.
- **The page reads only our own text**: one that names the app, reads as a sign-in code, and arrived after the
  code was asked for. Another company's code that arrives meanwhile is not read, so never leaves the phone.
- **Texts cost money and reach someone's phone**, so there are limits, all in `handles.dart`: three codes an hour
  and six a day for one install; the same for one number, whoever asks; ten tries of a code an hour; **200 texts a
  day in all** (`GHOST_TEXTS_A_DAY`); and only numbers that start `+1` (`GHOST_TEXT_TO`, a list like `+1,+44`).
  The last two are what a mistake, or someone making the server text numbers that pay them for it, can cost.
- A number verified on a new phone leaves the old one: one number, one install.
- **From the Mac it is done through the phone** (Matt, 2026-11-14: "on desktop the phone number reads as unknown and
  is not proxying the verification process"). The Mac shows the phone's number (`ownNumber` over the link) and its
  Number row opens the same page; each step is asked of the phone (`me` over the link: android `DeskCalls` →
  `DartAsk.kt` → the phone's `Me.forComputer`), so the code is texted to the phone and the number is linked to the
  phone's install, never the Mac's. The page on the Mac reads the code from the text as the phone hands it over.
  The phone's app must be open (Android keeps its Dart side only then; otherwise the Mac says so), and the phone
  needs 0.7.12 or later.

**A number is told to nobody.** It is not one of the accounts "Tell friends I'm here" speaks of: no app of ours
watches for a number, and the server answers nobody who does (`Handles._quiet`). Today it is a mark on your own
Settings page and a fact the server can rely on later. Letting friends who have your number hear that you joined is
the next step, and a decision of its own (see Not yet).

**What this costs in privacy, plainly.** The texting service (Twilio) is given the number, as it must be to text it.
The relay keeps the number's SHA-256, as it does a handle's, but a number is not a handle: there are only so many,
and anyone holding `handles.json` could hash every number in a country in an afternoon and read it back. So **the
server is to be thought of as knowing a verified number**, and which install it belongs to. It still holds no name
and no key for it.

## What the server keeps, and what it can see

`handles.json`, beside the pairings' `channels.json`:

- For each install that linked something, per network: **the SHA-256 of the handle, the SHA-256 of the network's own
  number for the account, and the day.** Never the handle, a name, a token, or anything else the network said.
- Which installs are **listed** (told to watchers). Off until the person turns it on.
- Each install's **watch list, as the same hashes**, and which of them it has yet to be told about.
- A secret the proof codes are made from.

An install is the hub's own name for it (made from its key, proved by a signature as it connects: `hub.dart`), so
only the install itself links, lists and watches for itself.

What that lets the server see beyond what the hub already saw: that an install has some account on a network, and
how many handles another is watching for. Someone who already knows a handle can hash it and find it in the file;
nobody can read a handle out of it. A verified phone number is the exception, kept the same way but few enough to
be worked back (A phone number, above). It holds no key or name, and tells nobody a number, so it cannot tell a
watcher how to reach the person who joined: the watcher is told the handle is on Uplink and asks them for their number where they
already talk.

**Nothing is said to the server about any of this until the person links an account, adds a handle, or opens
Settings › Me.** An install that never does is exactly what it was to the hub.

"Remove everything about me" deletes the install's links, listing, watch list and anything waiting for it.

## Setting up the three sign-ins (Matt's to do: they are accounts in his name)

All three want the address a sign-in comes back to. With the relay behind ghost-sms.com that is:

    https://ghost-sms.com/link/discord/callback
    https://ghost-sms.com/link/x/callback
    https://ghost-sms.com/link/telegram/callback   (Telegram asks only for the domain: ghost-sms.com)

1. **Discord.** discord.com/developers/applications › New Application ("Uplink") › OAuth2. Add the redirect
   above. Copy the Client ID and reset and copy the Client Secret.
2. **X.** developer.x.com › a Project and an App (the free tier is enough: it only asks who signed in). User
   authentication settings › OAuth 2.0, type "Web App" (confidential), callback as above, website
   `https://ghost-sms.com`. Copy the OAuth 2.0 Client ID and Client Secret.
3. **Telegram.** Message @BotFather: `/newbot` (name "Uplink", a username ending in `bot`), keep the token;
   then `/setdomain`, choose the bot, send `ghost-sms.com`.

Then their values, where the server reads them. Since the texting service's values (below) the way is the file on
the Mac, `~/.config/mattssoftware/ghost-relay.env`, put on the box by `deploy-relay.mjs --env`: these six lines go
in that same file. By hand on the box it was to be, as root, a file only root reads, and the relay started again:

    install -m 600 /dev/null /etc/ghost-relay/env     # mkdir -p /etc/ghost-relay first
    cat > /etc/ghost-relay/env <<'EOF'
    GHOST_DISCORD_ID=…
    GHOST_DISCORD_SECRET=…
    GHOST_X_ID=…
    GHOST_X_SECRET=…
    GHOST_TELEGRAM_BOT=…
    GHOST_TELEGRAM_TOKEN=…
    EOF
    systemctl restart ghost-relay

The relay says which sign-ins it has as it starts (`journalctl -u ghost-relay -n 5`). These are secrets: they go in
that file and nowhere in the repository.

## Setting up the texting service (Matt's to do: an account in his name, and it is paid for)

Twilio Verify, chosen because it needs no sender registered with the US carriers first (a plain texting number
does, which takes weeks), and because it makes and checks the code itself. As read on 2026-11-14, to be checked
against twilio.com/en-us/verify/pricing before relying on it: **$0.05 for each number verified, plus about $0.0083
for each text in the US.** A hundred people verifying is about six dollars. Nothing is charged for a code nobody
gets right.

1. **An account.** twilio.com, signed up and upgraded from the trial (a trial account texts only numbers it has
   itself verified).
2. **A Verify service.** Console › Verify › Services › Create new. Friendly name **Uplink**, exactly: it
   is the name in the text, and the app reads a code only from a text that says "ghost". SMS on; the code's length
   left at six. Copy the **Service SID** (`VA…`).
3. **Where it may text.** In Twilio's geo permissions for SMS and Verify, the United States and Canada only. This
   is the second lock on the same door as `GHOST_TEXT_TO`.
4. **A key.** Account › API keys & tokens › Create API key (standard). Copy its **SID** (`SK…`) and **secret**.
   The account's own SID (`AC…`) and auth token work too, but a key can be taken back by itself.
5. **The three values, written down on the Mac and nowhere else.** Never typed into a chat, a note or the
   repository: they are what lets someone send texts on the account's money. In
   `~/.config/mattssoftware/ghost-relay.env`, a file only Matt reads (`chmod 600`), one `NAME=value` a line:

       GHOST_TWILIO_SID=SK…
       GHOST_TWILIO_TOKEN=…
       GHOST_TWILIO_VERIFY=VA…

   With any of the three missing, verifying is off and the page says so. `GHOST_TEXT_TO` and `GHOST_TEXTS_A_DAY`
   need a line only to change `+1` and 200.
6. **The relay put up again with them** (Matt's word each time; it drops whoever is connected to the hub, and the
   apps connect again by themselves). From `messaging/`:

       node tool/deploy-relay.mjs --env ~/.config/mattssoftware/ghost-relay.env --glyph ~/Development/Apps/glyph

   `--env` installs that file on the box as `/etc/ghost-relay/env`, the file the relay's service reads as it
   starts, and prints the names in it, never a value. The file on the Mac is the one to keep: what the server
   needs is all in it, the sign-ins' values too once there are any (above), and a change is made there and
   deployed, not typed on the box.
7. **An app release that has the page** (0.7.12 or later; 0.7.11 went out without it).

To see it is on: Settings › Me › Number › **Text me a code** is a button, where before it said verifying is not set
up on the relay server yet.

## Putting it on the server

From `messaging/`, on the Mac (the box's account is Ghost.md's `tauri/.env`):

    node tool/deploy-relay.mjs --keep-connection && node tool/deploy-site.mjs --caddy

`deploy-relay.mjs` builds and installs the relay with the keeper of handles in it; its service now reads
`/etc/ghost-relay/env` where there is one. `deploy-site.mjs --caddy` adds `/link/*` to what ghost-sms.com's block
passes to the relay. A restart drops whoever is connected to the hub; the apps connect again by themselves.

**Done on 2026-11-14, both on one login at 18:02:03 UTC** (Matt, asked whether to deploy the server's half: "deploy
both yes"). The relay was up again at 18:03:52 and the block at 18:04:14, with every other site on the box
answering after as it had before, and `/apk.json` and `/mac.json` still served. `https://ghost-sms.com/link/`
answers from the relay; `tool/net/live_hub_test.dart` against `wss://ghost-sms.com/hub` passed after it (signed in,
a packet held and handed over, one answered, a room). There is no `/etc/ghost-relay/env` on the box yet: Discord,
X and Telegram are off in the app until their apps are registered and their values put there (above), which is
Matt's to do. The first run stopped before changing anything: the script's check that the port is the relay's own
went by the name `ss` prints, which is cut short ("dart:ghost-rela"), so the running relay looked like a stranger.
It now goes by the service's own process, and the second run went through on the same connection. What the hub
was holding in memory for people who were away at that moment was lost with the restart, as every restart loses it.

## Not yet

- **The number's code has not been sent by the real service.** The tests stand in for Twilio Verify with what its
  documentation says it answers (201 and `pending` for a text asked for; `approved` or `pending` for a code;
  404 once a code has run out; 429 when it has texted a number too often). The first real verification is the
  test of that, and of the text's wording being one the page reads. The server half is not deployed.
- **A verified number does nothing for anyone else yet.** The step after it: someone who has your number in their
  contacts hears you are on Uplink, as a watcher of a handle does. That means sending the server hashes
  of people's contacts, which can be worked back as above, so it wants its own decision, its own limits, and its
  own switch.
- **Not run against the real networks.** `handles_test.dart` and `me_test.dart` stand in for Discord, X, Telegram,
  Bluesky, Mastodon and GitHub with what their documentation says they answer. The first real sign-in on each is
  the test of that, X's token exchange most of all (a public client and a confidential one differ).
- **Told only while the app is open, or as it next opens.** The hub is the phone's Dart side; there is no push.
- **Joining does not start a conversation.** The watcher learns the handle is here, not the number. A friend
  request sent through the hub to someone found this way would close that gap, and needs the key exchange that is
  now done by text to be able to go by the hub.
- A paired computer shows the pages and cannot link or add (it speaks through the phone).
- X's follow list (its paid API), and Discord's and Telegram's friends (not offered to apps at all).
- Instagram, Threads, Signal, WhatsApp, Reddit and the rest: a network is one entry in `networks` (lib/me/me.dart) and
  one way of proving it in `handles.dart`.
