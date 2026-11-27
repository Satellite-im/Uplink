# Handoff: Uplink, 2026-11-13

**Since this was written (the same day, on Matt's Mac):** section 1 is done: ghost-sms.com has its Caddy block and
its certificate, and 0.3.1 was published as the first release, signed with the key now in `~/.config/ghostmessaging/`
(Matt was told to back it up, and to uninstall the cloud build and install from ghost-sms.com once). Section 2 is
done in 0.4.0: encryption in the conversation and the list, the nested Settings with its search, the expanded
settings read where they act, and Updates' plain words. 0.4.0 also has chat backgrounds, asked for that afternoon
(docs/RECORD.md). Section 3, the phone, is what is left. The branch is checked out as a worktree at
`~/Development/Apps/glyph-messaging`, so the shared checkout stays on main; the scripts are run from there with
`--glyph ~/Development/Apps/glyph`.

**The desktop companion, the same day** (Matt: "a companion desktop app that can proxy messages encrypted from my
phone to my desktop and then send back to the phone to send again", then "support both a relay server and local
networking"). Built on branch `claude/vigilant-meninsky-bfd14d`, which is this branch (0.6.2, `99175741`) and the
companion on top; it is not merged back, and nothing of it is released or deployed. `docs/desktop.md` is the whole
of it: how it works, how to run each part, what was tried on the emulator and what waits for the Fold.
- The Mac app is this Flutter project's macOS platform (`macos/`, `lib/desktop/`), not a project of its own, so it
  draws conversations with the phone's own screens. `flutter build macos`; `flutter build apk` is unchanged.
- The phone's half is `Desk*.kt` and Settings › Computers. 0.6.2 is merged in (0.6.1 before it, which the pairing
  was run on), and `pubspec.yaml` is 0.6.2+11 as it came: the version of the release with the companion in it is
  the releaser's. The phone app needs that release for the Mac app to have anything to pair with (Matt's camera on
  the Mac's QR code said no app could use it).
- The QR code is a link (`ghostmsg://pair/…`) the phone's camera opens in the app; conversations cross to the Mac
  a lot at a time. Both were run to the end on an emulator, on 0.6.1's tree and again on this one.
- The Mac app's icon is drawn whole by macOS 27 (it sat small on a grey plate: a black-and-white picture is stored
  as greyscale by the asset catalog, and macOS plates those; `tool/app_icon.py` and docs/desktop.md say the rest).
  A Mac that already drew the old one keeps it for that path until the app is touched or moved.
- The relay (`relay/`) runs on the Mac only. Putting it at `wss://ghost-sms.com/relay` is Matt's to say, each time;
  the wizard already starts with that address and says nothing answers there.
- To do on the Fold, in order: pair by scanning the Mac's QR code (never done with a real camera); see the Mac find
  the phone by itself on the Wi-Fi (never done: an emulator's network hides Bonjour; if it does not, the phone's
  address from Settings › Computers goes in the Mac's Settings); leave the phone overnight and see whether a text
  still reaches the Mac in the morning; answer macOS's one question about the local network.
- The Mac app is installed on Matt's Mac (/Applications/Ghost Messaging.app, 0.6.2 (456601), signed with the
  Developer ID, not sandboxed), paired with his phone since 2026-11-14 02:05 UTC, and updates itself
  (docs/desktop.md, "Updating itself"). Never drive or close that copy while he may be using it. To publish a Mac release, on Matt's word:
  `node tool/release-mac.mjs --publish`, and nothing before it: the site's block on the box has named `/mac.json`
  and `/ghost-messaging-mac.zip` since 2026-11-14 04:35 UTC (it went up again with the relay). It has not been
  run: `mac.json` answers 404 and installed copies read that as nothing newer. Not done: notarising (`--notarize`, for a download from a browser) and a download page.
- Three things the design asked Matt and he has not answered by name (docs/desktop.md, its last section).
- Android 16's local network permission is not asked for (targetSdk 36 does not need it); a later target will.

0.6.0, later still (docs/RECORD.md has each): what catches people coming from Google Messages (RCS, and Android's
restricted settings), a loading indicator and read errors, choosing several conversations to delete, the invisible
hello between two copies and the encryption banner, bubble colours, a settings cog in each conversation, the keyboard
coming back, the new icon, and speed; then the effects' own pictures (twenty sheets Matt made, cut into 240 sprites
by `tool/effect_sprites.py` and moved by the app) and four sticker packs made from the same ghost
(`tool/sticker_packs.py`; sent as picture messages), both tried on an emulator in a release build, where a sticker
was stored and drawn but, with no carrier, could not go. Two throwaway emulators (the spare AVD started twice, read-only) carried the
first real exchange between two copies of the app: the hello, both keys, a sealed text each way, a synced background.
They will not text each other, and their modems take no PDUs, so a small script carried each text across with
`adb emu sms send`.

0.6.2 also carries the effects' characters animated (78 strips of six drawings, `tool/effect_anims.py`, from
`~/Desktop/Animated`, which is not in the repository) and a fifth sticker pack, Mischief, cut from its own sheet.
There is a second sticker prompt on Matt's Desktop (a bunny pack) with no sheet made from it yet.

0.6.2, later that night: Matt reported picture messages not working. They had never run, so `tool/mms/` stands in
for a carrier on an emulator: sending (sticker, photo) and receiving both work there, and Android's own parser reads
what the app sends. The app now says why one fails, catches a carrier's refusal that Android calls sent, and asks
again for ones it could not fetch. Matt then said stickers work and photographs do not, and four faults were found
in the photograph's own path (trying again dropped the picture; the tap to try again did nothing on a picture; an
unreadable picture was left out silently; HDR photographs went as JPEGs with a gain map). Whether one of them is
what he met is not known until he tries it: Settings › Developer has the app's log to copy or share, which says
what each picture was made into and what the carrier answered.

0.6.1, that night: phones with a great many messages (docs/RECORD.md has the measurements). The list is read the newest
first and the rest behind, the lookups that were one question to Android per conversation are one for all, and a
conversation reads older messages as it is scrolled back. `tool/seed_store.py` fills a throwaway emulator's store
(3,000 conversations in three seconds, as root) to measure against; `setprop log.tag.GhostPerf VERBOSE` times each
call.

0.5.0, later that day, added two more asks of Matt's (docs/RECORD.md): a conversation's background synced between phones
that both have the app, as a text in the conversation, and sign-in codes handed to Ghost Keyboard (which needs its
0.18.0: the `codes` branch of GhostKbd, in `~/Development/Apps/ghost-kbd-codes`, not pushed until Matt says).

Written by the cloud session that built 0.1.0 to 0.3.1, for the session that carries on from Matt's Mac (Matt:
"give me a full prompt to have another session pick up the work on my mac"). The cloud session had no account on the
box, no release key, no phone and no emulator, so nothing here has been published or run on a device.

Branch: `ccr-47d364dc-sj9ic1` of InfamousVague/glyph. The app is `messaging/`; read `messaging/docs/RECORD.md` first (it was the README until 2026-11-27; `README.md` is now the front page for someone meeting the app).

## 1. Publish (the reason for the move)

Matt, 2026-11-13: "add auto update and serve it over ghost-sms.com I'll point the domain to the same server ghost kbd
uses", then "the auto update is throwing an SSL error, did you setup the domain on the box" (it had not been: no
block for ghost-sms.com in the box's Caddyfile, so no certificate), then "http://ghost-sms.com is pointing to caddy
for me" (DNS is done).

From `messaging/`, with Ghost.md's `tauri/.env` present (the scripts find the checkout as the folder above):

```sh
node tool/deploy-site.mjs --print --caddy   # read what the box would run first; nothing is sent
node tool/deploy-site.mjs --caddy           # site/ into /opt/ghost-sms-site, and ghost-sms.com's block in /etc/caddy/Caddyfile
node tool/release.mjs                       # build, sign, check, upload to /opt/ghost-sms-release, verify it is served
```

- Both are Ghost Keyboard's `tool/deploy-site.mjs` and `tool/release.mjs` adapted by script and **never run against
  the box**. Read them through before the first run. The Caddyfile is shared with attack.fm, ghostmarkdown.com,
  ghostkbd.com and more; `--caddy` backs it up, touches only ghost-sms.com's own blocks, validates, reloads, and puts
  the backup back if any other site answers differently. The box counts logins: each script spends one.
- The first `tool/release.mjs` makes the release key in `~/.config/ghostmessaging/` (signing.properties,
  release.keystore, cert.sha256). Tell Matt to back that folder up: losing it means every copy reinstalls.
- `android/app/build.gradle.kts` signs release builds with that key when it is there.
- Check after: `https://ghost-sms.com/` (the page), `/apk.json`, `/ghost-messaging.apk`.
- **Matt's phone has a cloud build, signed with a throwaway debug key.** It cannot update to the release. He
  uninstalls it and installs from ghost-sms.com once (messages are Android's and stay; the app's own settings, pins,
  archive, drafts, edits record and encryption keys start again). Say this to him plainly before he wonders why
  "Update now" fails.
- Wanted and not done: Settings › Updates should say "ghost-sms.com isn't serving updates yet" for a TLS, DNS or 404
  failure, where it now shows the raw error (`_updateLine` in `lib/ui/settings.dart`).

## 2. Finish what was in hand

Matt, 2026-11-13: "make the settings page more like ghost kbd where it's nested sections and expand on the settings
available. also enable an option for an additional level of E2E encryption by allowing users to exchange keys somehow
and then encrypt all messages so only others with the app can read them".

### Done and committed (builds; analyzer clean; Dart and JVM tests pass)

- `E2eCrypto.kt` (pure JVM, `E2eCryptoTest`, 5 tests): P-256 key pair per phone, the public half in a text as
  `ghost:k1:` + 44 base64 characters, ECDH + HKDF-SHA256 for the conversation's key, AES-256-GCM messages as
  `ghost:e1:` + base64, a 30-digit safety number, a fingerprint.
- `E2e.kt`: this phone's key kept under an Android Keystore AES key; per person none / offered / pending / on, with
  `changed` when a different key arrives (back to pending, verified cleared); `wire()` seals, `read()` opens.
- Wired in natively: `Sender.send` seals to one person when on (`plain = true` sends the key text itself);
  `SmsDeliverReceiver` keeps an arriving key (`E2e.received`); `Store.messages` opens sealed rows and adds
  `encrypted` and `notice` ("key", "undecryptable"); `Store.conversations` previews through `E2e.preview` and adds
  `encrypted`; `Store.editMessage` keeps a sealed row sealed; `Notifier` words the two notices.
- Channel calls in `MainActivity.kt`: `e2e`, `e2eOffer`, `e2eOff`, `e2eVerify`, `e2eReset`, `e2eMine`, `e2eList`,
  `blockedNumbers`, `notificationSettings`.
- Native settings already read from the "ui" preferences: `delivery_reports` (Sender), `read_reports` (Sender),
  `notif_preview` and `notif_code` (Notifier). All default on.
- Dart: `lib/sms.dart` has `E2eState`, `Message.encrypted` / `.notice`, `Conversation.encrypted` and the calls above.
  `lib/app_state.dart` is now a map of preferences with `choice` / `flag` / `set` / `setFlag` and getters `textSize`,
  `textScale`, `bigEmoji`, `foldReactions`, `enterSends`. `lib/ui/encryption.dart` has `showEncryptionChoices` and
  `showSafetyNumber`. `lib/effects.dart` has `effectLabel` and `effectTriggers`.

### Not done

1. **Nothing in the app's screens uses the encryption yet.** In `lib/ui/thread.dart`:
   - load `Sms.instance.e2e(address)` for a one-person conversation (and again on each change);
   - a lock and "Encrypted" (or "Encrypted · verified") in the header's second line when on;
   - a bar above the composer when pending ("Maya wants to encrypt this conversation" / "sent a NEW key", Turn on)
     and when offered ("Waiting for Maya to accept");
   - the header's people sheet (`_showPeople`) gets an Encryption choice that opens `showEncryptionChoices`;
   - the composer's placeholder says "Encrypted message" when on, and a picture attached in an encrypted
     conversation says it goes unencrypted (MMS is not sealed);
   - a message with `notice == 'key'` is a small centred line ("You sent your encryption key" / "Maya sent an
     encryption key"), not a bubble; `'undecryptable'` is a bubble saying "Encrypted message that can't be opened
     on this phone";
   - a small lock beside the ticks of a message with `encrypted`.
   In `lib/ui/conversations.dart`: a small lock after the name where `c.encrypted`.
2. **The nested Settings is not written.** `lib/ui/settings.dart` is still one long page. Wanted: a home of grouped
   section rows with a search field, each opening its own page, as Ghost Keyboard's `lib/settings/settings_screen.dart`
   does (`SettingsList`, `_Group`, `_SectionRow`, `SectionPage`: port their look; `lib/kit/` already has the rest).
   The sections planned, with what each holds:
   - Appearance: theme, your bubbles, text size (`text_size`: small, default, large, larger; `AppState.textScale`
     is not applied to the bubbles' text yet).
   - Emoji: the sets; "Large emoji" (`big_emoji`, not read by the thread yet).
   - Effects: the switch, and every effect by name with what sets it off, a tap playing it over the page.
   - Messages: "Enter sends" (`enter_sends`, not read by the composer yet), "Attach reactions to messages"
     (`fold_reactions`, not read by the thread yet).
   - Receipts: delivery reports (`delivery_reports`), read receipts (`read_reports`), the ticks explained.
   - Notifications: Android's permission, message previews (`notif_preview`), the copy-code button (`notif_code`),
     sound and vibration (opens Android's page: `Sms.instance.notificationSettings()`).
   - Encryption: what it is and is not, this phone's key (`e2eMine`), the people (`e2eList`, each opening
     `showEncryptionChoices`), "New key for this phone" (`e2eReset`, with a confirmation).
   - Blocked numbers (`blockedNumbers`, tap to unblock), Archived (opens the archived list), Your number.
   - Android (default SMS app, contacts), Updates, About (version, what it is, the emoji sets' licences).
3. `test/screens_test.dart` then needs the new channel calls answered (`e2e`, `e2eList`, `e2eMine`,
   `blockedNumbers`) and pictures of the settings home, a section page, and an encrypted conversation.
4. docs/RECORD.md: an "Encryption" entry and the settings; version 0.4.0 in `pubspec.yaml` and About.

### Say to Matt about the encryption, as it is

- One person at a time. Group conversations and picture messages are MMS and are not encrypted.
- The keys travel by SMS, so a carrier could swap one on the way; the safety number, compared in person or on a
  call, is what rules that out.
- No forward secrecy: there is no ratchet. It is not Signal's protocol.
- A sealed text is longer (base64, plus 28 bytes), so it costs more SMS parts.
- The other person must have Uplink; to anything else a sealed text is a line of letters.

## 3. Try it on the phone

Nothing below has run on a device. With the Fold connected, in this order: become the default SMS app and see the
old conversations; send and receive an SMS; delivery ticks; a picture each way and a group MMS (the wire format is
`Pdu.kt`, held only by `PduTest`); a notification with Reply, Mark as read and Copy code; a reaction each way with a
phone on Google Messages and with an iPhone; an edit with its correction; each emoji set, joined emoji among them;
an effect arriving; block and unblock; the updater against the first real release; encryption between two
phones with the app; a sticker each way (it is a picture message: does its clear background arrive, on a phone
with the app and on one without); and a voice message each way, with an iPhone and with a phone on Google Messages
(it is an MMS with an `.m4a` in it: does it arrive, does it play there, does theirs play here, and how long does
the Fold's carrier let one run); and the frame (`lib/ui/shell.dart`): the Fold opened out shows the list beside the
conversation, closing it with a conversation open keeps that conversation and what is half written in it, back
closes the conversation before it leaves the app, and a notification opens its conversation in either state.

## Ways of working that Matt has asked for

- He reads replies on his phone: short, plain, the outcome first.
- Each build goes to his phone. In the cloud that was a file sent in chat; on the Mac it is the Fold over adb, or
  the release he updates to.
- Commit messages and the record (docs/RECORD.md) quote his ask and say what was done and where, as the ones in this branch do.
- The Glacier kit in `packages/glacier/` is a copy: change the kit upstream in Ghost.md, never here.
