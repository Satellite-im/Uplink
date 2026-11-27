# Uplink on the desktop

Matt, 2026-11-13: "Is it possible for us to make a companion desktop app that can proxy messages encrypted from my
phone to my desktop and then send back to the phone to send again?", then "I'd like to support both a relay server
and local networking, it should attempt to use local networking by default and show the option for both in the setup
wizard". This was written as a design first; he read it and said "Yes, build it". It now says what was built, the
same day, and what has and has not been tried. It sits on the phone app's 0.6.2.

The phone stays the only thing that texts. The Mac shows what the phone has and asks the phone to send.

| Part | Where | What |
| --- | --- | --- |
| The phone's half | `android/…/Desk*.kt`, `WsClient.kt`, `ScanActivity.kt`; `lib/ui/computers.dart` | Answers the Mac from Android's own messages, sends what it asks; Settings › Computers |
| The Mac app | `macos/` and `lib/desktop/` (the same Flutter project, so the phone's screens, fonts and Glacier are its own) | The wizard, the conversations beside the one open, a composer, Settings |
| The relay | `relay/` (Dart's own library and nothing else) | Passes sealed frames between the two when they are on different networks |

## Pairing

1. The Mac's wizard asks how to connect: **Local network, then relay** (the default), **Local network only**, or
   **Relay only**, and for the relay's address, saying whether a relay answers there. Then it shows a QR code.
2. The code holds a public key made for this pairing, sixteen random bytes (the secret), the Mac's name, the choice
   and the relay's address. It crosses no network: it goes from the screen to the camera. In the QR code it is a
   link, `ghostmsg://pair/…`, because a phone's own camera can open a link in the app that takes it and can only
   show plain words (Matt, pointing his camera at the first one: "linking the Qr code said it can't be used by any
   app on my phone"). As words to paste it is `GHOSTPAIR1:…`, the same letters after the tag.
3. The phone: point its camera at the code and open the link in Uplink; or Settings › Computers › Pair a
   computer, which scans it (the camera and ZXing, on the phone) or takes it pasted. A code that came from outside
   the app is asked about before anything is done with it ("Pair with Matt's MacBook Pro?"), since anything can
   open a link. Its page shows the same three choices, set as the Mac had them, and can change them: the phone's
   choice is the pairing's.
4. The phone makes its own key pair and listens; the Mac, which is looking (the local network first, then the
   relay, as it chose), connects and is given the phone's public key.
5. Both make the pairing's key the way `E2eCrypto.kt` makes a conversation's: P-256 ECDH, then HKDF-SHA256 salted
   with both public keys. The secret goes in too, so whoever swaps a key on the way ends up with nothing.
6. Both show six digits made from that key. "They match" on both, and they are paired. The two private keys are
   thrown away; each side keeps only the pairing's key (the phone under an Android Keystore key, as `E2e.kt` keeps
   its own; the Mac in its Keychain, or in a file only the account can read where the build is not properly signed).

## Sealing

Everything after pairing is sealed, on the local network as much as through the relay (`DeskCrypto.kt`,
`lib/desktop/link/crypto.dart`).

- Each connection starts with a hello each way, in the clear: which pairing (a name made from the key, that says
  nothing of it), a fresh random number and a throwaway public key. The connection's two keys, one for each
  direction, come from the pairing's key, both random numbers and what the throwaway keys agree on.
- Each frame is AES-256-GCM with a counter as its nonce, never sent. A frame that is repeated, dropped, out of order
  or changed does not open, and the connection ends.
- Why more than `E2eCrypto.seal` as it is: a relay that replayed "send this text" would text someone twice. The
  throwaway keys also mean a pairing key taken later does not open what was recorded earlier.
- The first sealed frame each way is `ready`: it is what shows each side that the other holds the key. Nothing is
  answered before it.

## What they say to each other

JSON inside the seal, shaped like `lib/sms.dart`'s channel: on the Mac the phone's own screens run, and their calls
go to the phone (`lib/desktop/remote.dart`). The Mac asks (`req`), the phone answers (`res`), either says what
happened (`ev`).

| The Mac asks | The phone (`DeskCalls`) |
| --- | --- |
| `conversationsPage`, `conversation`, `archivedCount`, `messages`, `people`, `searchContacts`, `contact`, `threadFor`, `e2e` | answers from `Store.kt` and `E2e.kt` |
| `part` (in pieces), `photo` | a picture's or a face's bytes |
| `send` (a name for the text, the numbers, the words) | `Sender.send`, once for each name |
| `markRead`, `threadFlag` (pinned, muted), `archive`, `draft`, `setDraft` | does it on the phone |
| | `changed` (a conversation), whenever a text arrives, is sent or changes state |

- **Since 2026-11-14 the computer does what the phone's screens do** (Matt: "Unify the UI experience … the desktop
  app should get all featues its missing from mobile"; "Add an emoji picker, file upload, voice memo and sticker
  selector to the desktop app as well"). The first design had a computer read, send text, mark read, pin, mute,
  archive and keep a draft, and refused the rest. It now also asks, and the phone does:

  | The Mac asks | The phone |
  | --- | --- |
  | `deleteMessage`, `deleteThread`, `deleteThreads`, `editMessage`, `resendMms` | as its own screens do |
  | `setBlocked`, `blockedNumbers` | Android's blocked numbers |
  | `e2eOffer`, `e2eOff`, `e2eVerify`, `e2ePlainSeen`, `e2eList` | encryption with someone: its key goes, it is turned off, a safety number marked |
  | `mmsStatus`, `voiceLimit` | what would stop a picture message; how long a voice message may run on its carrier |
  | `put` (a piece), `drop` | keeps what the computer is handing over, by the name the computer gave it |
  | `sendPictures`, `sendVoice`, `sendSticker` (a name for it, the numbers, what was handed over) | sends it as it sends its own, once for each name |
  | `caps` | the names above: what this phone does for a computer |

  Still refused, since they are the phone's alone: its encryption key (`e2eReset`, `e2eMine`), its settings, its
  other paired computers, its log, its own update.
- **Handing over.** A frame holds less than a megabyte and a picture is more, so what the computer sends crosses in
  pieces of 384 KB (`put`: a name the computer makes, where the piece starts, how long the whole is), in order; a
  piece come twice is answered and kept once. The phone holds up to eight at a time, 12 MB each, 36 MB in all, for
  five minutes, in memory; the call that sends takes them and they are gone. A picture is then written to the
  app's cache for as long as `Sender.send` takes to make it fit the carrier, and removed.
- **An older phone.** A phone whose app is from before this answers that it does not do `caps`, and the computer's
  screens offer none of it (`Sms.can`, `LinkCalls.caps`): they are asked each time the phone is reached, since it
  may have been updated since.
- **What the Mac does itself** (`macos/Runner/DeskChannels.swift`, `DeskSound.swift`): the Mac's own panel to
  choose pictures; its own "Emoji & Symbols", which types into the field the cursor is in; a voice message
  recorded with its microphone (AAC in an `.m4a` at 24 kbit/s, as the phone records its own, stopped at what the
  phone says a message may weigh; macOS asks for the microphone the first time) and played from the bytes the
  phone hands over. A recording is in the temporary directory only until it is stopped.
- Conversations cross a lot at a time, newest first, as 0.6.1's own list reads them: the newest forty and the
  pinned at once, the rest behind them, never more than 250 in one answer. An answer too long for one frame is
  refused in words ("Too much to send at once") and the connection stands. Every lot is whole in itself (each row
  with its conversation's newest words, Google Messages' bridge's among them, and where its lot ends as `floor`),
  and the first also carries the newest few unread ones from further down. A conversation that comes twice in one
  reading is kept as the copy with the newer message, so a phone on an older build, whose later lots carry a
  conversation as Android alone has it, does not put its last SMS over a newer RCS message.
- "Are you there" (`ping`) is answered where it arrives; the list is read on one thread, a text sent on another,
  the rest on a third. A long read or a slow send holds nothing else up, and never makes the Mac think the phone
  has gone.
- `send` carries a name the Mac made. The phone remembers the last five hundred and never sends one twice, so a
  retry after a dropped connection cannot double a text.
- A conversation encrypted phone to phone works as it does on the phone: the phone opens and seals those texts, and
  they cross to the Mac under the pairing's seal.
- Either side says `mode` when how to connect is changed, and `unpaired`.
- Later: files that are not pictures (the phone sends only pictures today), Mac notifications, Windows and Linux.

## Local network

- The phone listens on a port (the same one each time, when it is free) and announces `_ghostmsg._tcp` (Android
  NSD), again when its network changes. The Mac looks for it (Bonjour, `macos/Runner/DeskChannels.swift`) and
  connects, trying where it reached the phone last first.
- The phone listens, not the Mac, because a phone announcing is the dependable direction with its screen off, and
  the Mac then opens no port. macOS asks once to let the app find devices on the local network.
- Where a network keeps the two from finding each other, the phone's address (Settings › Computers on the phone)
  can be typed in the Mac's Settings › Your phone.
- Anything else that connects cannot finish the hello and learns nothing.

## The relay

- A WebSocket server both ends dial out to (`relay/README.md` has what is said to it). A pairing has a channel and a
  token, both made from the pairing's key. The relay keeps the token's hash from the first connection and lets in
  only those who hold it, one phone and one computer, and passes frames from one to the other. If the other end is
  not there the frame is dropped and the sender is told.
- **What it stores:** for each pairing, the channel, the token's SHA-256 and the day it was last used. No texts, not
  even sealed ones; no queue; no names or numbers; no log of addresses.
- **What it can see:** that two addresses share a channel, when, and how much they send.
- Unpairing from either side removes the channel. One unused for ninety days is removed.
- Pairing through the relay uses a channel made from the QR code's secret in the same way, which goes as soon as
  both have left it and after ten minutes at most.
- **It is on our server since 2026-11-14** (`relay/README.md`, "On our server"): the wizard's own address,
  `wss://ghost-sms.com/relay`, answers. A phone and a Mac pairing through it there has not been tried yet.

## Which way a message goes

With both allowed, the Mac tries the local network first: where the phone was last, what Bonjour finds, an address
given by hand. Only when none answers does it connect through the relay, which it holds ready meanwhile. While the
relay carries the connection it tries the local network again every fifteen seconds and takes it when it answers.
The choice can be changed later from either side, and the change is sent to the other, sealed.

## When the phone is asleep, or Android stops the app

- While a computer is paired, or being paired, the phone runs a foreground service (`DeskService`, Android's
  "remote messaging" kind). Android has it post a notification ("Paired with Matt's MacBook"), on a channel that is off from the start, so it is not shown (Matt, 2026-11-14: "don't show the notification for the phone app and desktop app being linked it's blocking notifications for text messages"); Android's own notification settings for the app (Paired computers) turn it on. It holds the port and
  the relay connection, and starts again after a restart or an update. It stops when no computer is paired.
- If Android stops it anyway, a new text starts it again, and the Mac reads what it missed when it reconnects.
- In deep sleep (still, unplugged, screen off a long while) Android cuts the app's network. What is typed on the
  Mac waits there, drawn as "Waiting for your phone", and goes when the phone is back. Settings › Computers leads to
  Android's battery setting for those who want the phone reachable in deep sleep.
- Nothing waits on the relay, ever. The Mac keeps the pairing, its own choices, and what it has read from the
  phone (below, "What the Mac keeps").

## What the Mac keeps

Matt, 2026-11-14: "cache messages on the desktop app so that we don't need to fetch them all from the phone every
time, just fetching updates in the background". Until then every list and every conversation was asked of the
phone each time it was shown, and the Mac opened empty until the phone answered.

- **Kept** (`lib/desktop/cache.dart`, a `cache` folder in the app's own): the list of conversations, and each
  conversation's messages as the phone last gave them, up to as many as were asked for. Not pictures, voice
  messages or videos, which are fetched as they are shown.
- **Sealed.** Each file is AES-256-GCM (`DeskCrypto.sealAtRest`) under a key made from the pairing's key, which
  is in the Keychain. Nothing in the folder can be read without it. Unpairing deletes the folder, and Settings ›
  Kept on this Mac says how much there is and clears it.
- **Answered from what is kept** (`lib/desktop/remote.dart`). The list and a conversation that has been read
  before are on the screen at once, the phone there or not. The phone is waited for only where nothing is kept,
  where more is asked for than is kept (reading back, until the phone has no more), and after something done from
  the Mac that the phone has to make something of (a picture sent, a message deleted).
- **Only what is new is fetched, behind the screens.** When the phone says a conversation changed, the Mac asks for
  its line in the list and its newest forty messages and joins them to what it keeps (`LinkCalls.merged`: the
  newest are the phone's, the older stay, one deleted among the newest goes); where more came than forty, the
  conversation is read whole. Each conversation is read whole once each time the app runs, so what was deleted or
  changed far back is put right. When the phone is reached again everything is taken for possibly changed and
  read again in the same way. The screens are told when what is kept changed, and read it.
- **Ahead.** After the list is read, the eight conversations at its top have their messages read too, one after
  another, so each opens at once though it was never opened here.
- The first time, with nothing kept, the list asks the phone for its first lot as it did, and all of it is read
  behind that.

## Unpairing

- The phone: Settings › Computers lists each one (its name, how it is connected now or when it was last seen, how
  it connects); a press chooses among the three ways, or Unpair. The Mac: Settings › Your phone › Unpair this phone.
- Either one deletes its key, tells the other if it is connected, and has the relay forget the channel.
- A side that was away: through the relay, the Mac hears from the phone that the pairing is gone and says so. On the
  local network alone the Mac goes on waiting, and is unpaired there by hand.

## Updating itself

Matt, 2026-11-13: "install the app on my mac and make sure it has OTA updates so we don't need to reinstall again".
The Mac app updates itself as Ghost.md's Mac app does (the same steps, carried over from `macos/Runner/
UpdatesChannel.swift` in the repository's root, where they have run since 2026-10-24).

- **What it reads** is `https://ghost-sms.com/mac.json`, beside the phone app's `apk.json`: `{ version, versionCode,
  sha256, bytes, url }`, the url being `ghost-messaging-mac.zip`, the signed app zipped by `ditto`. Newer is a
  `versionCode` (the app's `CFBundleVersion`) above its own. It looks as it opens and every six hours, and from
  Settings › Updates › Look for an update (`lib/desktop/updates.dart`).
- **What it believes.** The download is held to the size and SHA-256 the description gives. Then what came out of
  the zip has to be this app (its bundle id), newer (never a step back), and whole and signed by this app's own
  team: `anchor apple generic and certificate leaf[subject.OU] = "F6ZAL7ANAD"`, every architecture and every nested
  library, strictly (`macos/Runner/UpdatesChannel.swift`). Only Matt's Developer ID signs as that team, so nothing
  the server or the network says can stand in for it, and there is no second key to keep or lose.
- **How it is put in place.** Unpacked beside the running app in a hidden folder
  (`/Applications/.Uplink.app-update`, named for the installed copy's own file), then the two trade places in one step, the app quits, and a small
  helper opens the new one and removes the old only once the new one has said it opened; if it has not in two
  minutes the old one is put back. A bar over every page offers Restart to update; quitting swaps it in as well, so
  the next launch is the new version either way.
- **Not sandboxed**, since a sandboxed app cannot replace itself (`Runner/Release.entitlements` says so). It is
  signed with the Developer ID under the hardened runtime and asks for no entitlement.
- **Making a release**: `node tool/release-mac.mjs` builds, signs inside out, checks what an installed copy will
  ask, zips, and writes `mac.json` into `build/release-mac`. `--install` puts the app in /Applications (once),
  `--notarize` has Apple notarise it (for a copy downloaded with a browser; a copy that updates itself is not asked
  for it), `--publish` puts the two files on the box as `tool/release.mjs` does the phone's. The number is the
  minutes since 2026 began, so it rises by itself.
- **The first release** is `node tool/release-mac.mjs --publish`, on Matt's word, and nothing before it.
  ghost-sms.com's Caddy block serves the release folder's files by name, and it has named `/mac.json` and
  `/ghost-messaging-mac.zip` beside the phone's two since 2026-11-14 04:35 UTC, when the phone session put the
  block up again with the relay (`tool/deploy-site.mjs`). Until a release is published `mac.json` answers 404, which
  an installed copy reads as nothing newer.

**Tried on this Mac, 2026-11-14**, with two builds signed as a release is (456590, then 456591) and a local server
standing in for ghost-sms.com (`GHOST_DESK_UPDATES=http://127.0.0.1:8793/mac.json`, `GHOST_DESK_UPDATE_RESTART=now`
so no hand is needed): the older read the description, brought the zip down, checked it, swapped itself, quit, and
was opened again as the newer in six seconds, the old one removed (`~/Library/Caches/com.infamousvague.
ghostmessaging.mac/update-install/install.log` has each step). An update changed after it was signed was refused
("the download's signature is not whole"), and so was one signed by somebody else ("not signed by Uplink's
developer"); the running app was left as it was both times. The copy in /Applications then took
itself from 456600 to 456601 the same way. **Not tried**: an update from ghost-sms.com itself (nothing is
published there), `--publish`, `--notarize`, and quitting with an update waiting (the swap is the same code as
Restart; what differs is that nothing reopens the app).

**The old version put back, seen for real** (2026-11-14 02:08 UTC, and a mistake in how it was tried). A second
walk-through was started on the copy in /Applications while Matt had that app open and paired. With one copy of
the app already open, `open` only brings that one forward, so the new version (456605) never said it opened, and
after two minutes the helper put the old one (456601) back and opened it: the safety net working as written. But
the walk-through's script had by then closed Matt's own open app, taking it for the one the helper opens, and the
copy the helper opened carried the walk-through's settings (`GHOST_DESK_DIR`, a folder with no pairing in it), so
it showed the pairing wizard, which read to him as the pairing being lost ("I keep having to re pair every time
the app opens"). It was not: opened again with no such settings, the app showed his conversations and connected
to the phone with the pairing made at 02:05, its key read from the Keychain. Two things to keep: never walk an
update through a copy somebody has open (look for a running copy first, and close only what was started), and an
app the helper opens has the environment of the app that asked for the restart.

What is in /Applications is 0.6.2 (456601). The newer build made since (0.7.1, 456605, in `build/release-mac`) is
what a first published release would be; the installed copy would take it by itself.

## What changed in the phone app

- The camera permission (asked for when scanning), a foreground service, starting at boot.
- "The updater is the only connection the app opens" is true only while no computer is paired.
- One library, ZXing, to read the QR code on the phone. Nothing from Google Play.

## Trying it

```sh
flutter test                                    # sealing held to test/desk_vectors.json; the Mac's link against a
                                                # stand-in phone and the real relay; every screen, phone and Mac
cd android && ./gradlew :app:testDebugUnitTest  # the phone's sealing (the same examples), its session, its WebSocket
                                                # client, a QR code read from a frame
cd relay && dart test                           # the relay
flutter build macos                             # build/macos/Build/Products/Release/Uplink.app
```

Against an emulator, the real Mac app and the real phone app (`integration_test/desk_live_test.dart` says how):
Bonjour cannot cross the emulator's network, so the Mac is given the phone's address through `adb forward`, and the
relay on the Mac is reached from the emulator through `adb reverse`. `adb shell setprop log.tag.GhostDesk VERBOSE`
has the phone write each thing a computer asks for to Android's log, by name and milliseconds, never what it held.
Use an emulator nothing else is using: two runs stalled on one another session was driving at the same time.

The Mac app's icon (Matt: "the icon on the mac app is also not full width and height, it's inset"): macOS 27 drew
it small on a grey plate of its own. Not for its outline, which was redrawn three times to no end: the picture is
black and white and nothing else, Xcode's asset catalog stores a picture with no colour in it as greyscale, and
macOS puts a greyscale icon on a plate whatever its outline (one pixel that is not grey, and the same picture is
drawn whole). `tool/app_icon.py` gives the Mac icon's black two parts in 255 of blue and refuses to write one that
is all grey; `python3 tool/app_icon.py --check "build/macos/Build/Products/Release/Uplink.app"` says how
the built app's catalog stored it. macOS keeps the picture it made for an app at a path: `touch` the app after a
rebuild (or move it) and the Dock draws it again. Seen whole on the app as built, by `NSWorkspace`'s icon for it.

The Mac app's top bar (Matt: "make the top bar on the mac app black"): the window's title bar is black in the light
theme and the dark (`macos/Runner/MainFlutterWindow.swift`). The title bar is given no material of its own, so the
window's colour, black, shows there, and the window's own chrome is drawn as on a dark window, so the title is
white and the three buttons read on it. Only the window is told so: the pages still follow the Mac's light or dark
setting, which Flutter reads from the system and not from the window. Seen on the app as built, by a picture of its
window with the pages dark (bar 0,0,0 over a page of 5,4,4) and with them light (bar 0,0,0 over 254,253,254; the
light pages were had by starting the app with `-AppleInterfaceStyle Light`, the Mac itself being in dark).

**Tried on 2026-11-13**, the Mac app and the phone app on the spare emulator: paired over the local network, through
the relay, and with both allowed (where the local network was taken first); the six digits the same on both each
time; the conversations listed; a text arriving on the phone shown on the Mac within a second or two; a text typed
on the Mac in the phone's own store as sent; unpaired from the Mac and from the phone, the other told and the relay's
channel removed; the service and its notification there while paired and gone after. The scanner opens and shows the
camera. Then again on 0.6.1's tree, each pairing started as a camera would start it, by opening the QR code's link
on the phone: the question, the digits, the list a lot at a time, a text each way (the phone's own store holding
the Mac's as sent) and unpairing, over the local network three times, through the relay, and with both allowed.
And once more with both allowed after 0.6.2 was merged in: paired through the relay, then the local network taken.

**Not tried**, since they need the Fold or a signed build: the two finding each other by Bonjour and NSD on a real
network (Matt's own pairing on 2026-11-14 went over it, the Mac dialling the phone's address on the Wi-Fi; nobody
watched how the two found each other); reading the QR code with a real camera (he paired, by the camera or the
pasted code, which is not known here); the service
through a night of deep sleep, and whether a text arriving brings it back; anything on a carrier.

No longer on that list: the Keychain in a signed build. The copy in /Applications (Developer ID) kept the pairing's
key there when Matt paired on 2026-11-14 (`pairing.json` holds no key; the Keychain item is dated the same second)
and read it back on two later starts, each of which showed his conversations and reached the phone.

## Matt has not said

The design asked three things, and "Yes, build it" answered none by name, so it is built as the design had it:

1. ~~The permanent notification on the phone while a computer is paired.~~ Still posted, as Android has it, on a
   channel that is off from the start, so it is not shown (2026-11-14).
2. ~~The Mac keeps no texts on its disk, so it opens empty until the phone answers.~~ It keeps what it has read,
   sealed, since 2026-11-14 ("What the Mac keeps").
3. The relay at `ghost-sms.com/relay` when he says, and on the Mac until then.
