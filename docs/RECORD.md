# Uplink: the record

Everything the app does, as it was asked for and built: each feature with its date, Matt's own words and where it lives
in the source, then how the app is built, how to build it and how it is released. This was `README.md` until
2026-11-27; the README is now the front page for someone meeting the app (Matt: "create a user friendly updated
version of the readme"), and this is what a developer reads. **A release's entry is added here**, at the top of
"What it does".

Uplink was Ghost Messaging until 2026-11-27, and began as an SMS and MMS app for Android that replaces the phone's
default messaging app, drawn with **Glacier**, the same UI kit Ghost.md and Ghost Keyboard use.

Started 2026-11-13 at Matt's ask: "Sketch out a project and load it on my phone, use the same glacier UI we use for
other projects like ghost MARKDOWN and ghost KBD include basic functionality so i can replace my current sms today".
It is developed in Ghost.md's repository, in its own folder, and published whole as its own repository
(github.com/InfamousVague/ghost-messaging) with each release (tool/publish-source.mjs).

## Open source, for privacy

Uplink is open source so anyone can check what it does with their messages (Matt, 2026-11-15: "I want to
open source it for the privacy focused nature"). All of it is here: the phone app, the Mac and Windows apps, the
relay server (`relay/`) that carries messages between your own devices and between friends, the call processing
(`native/voicefx`) and the Google Messages helper (`sidecar/gmessages`, also at
github.com/InfamousVague/ghost-gmessages-sidecar).

- **Licence:** the GNU Affero General Public License v3 (`LICENSE`). Anyone who runs a changed copy, the relay
  included, for others to use owes those people its source.
- **What is not here:** the keys releases are signed with (Android's and Apple's), and the server's own credentials
  (Twilio and the like, read from its environment). Builds made from this source are not signed as the releases are,
  so they install as a separate app.
- **Third-party parts** keep their own licences: the emoji fonts (`assets/emoji/LICENSES.md`), Inter and JetBrains
  Mono (`assets/fonts/OFL.txt`), RNNoise (`native/voicefx/rnnoise/COPYING`, BSD), DeepFilterNet (MIT or Apache-2.0)
  and mautrix-gmessages' libgm (AGPL-3.0).

## What it does

- **Becomes the default SMS app**: the first screen asks Android for the SMS role. Every existing conversation is
  there straight away, because messages live in Android's own SMS/MMS database (the Telephony provider), not the
  app. Switching back to another SMS app loses nothing.
- **A removed device stops being the account, on the account's own word; the app in a browser** (not released; the
  `web` branch, with its three reviews). A device removed from Settings › Me › Signed in on these devices is handed the
  account's signed removal by the relay (`relay/lib/accounts.dart`, kept through every backup brought up to date) and,
  having checked it, deletes everything of the account if it is an iPhone, a computer of its own or a browser
  (`lib/account/account.dart` `check`); an Android phone, or a computer linked to one, forgets the account's words and
  keys as before. **Release order: deploy the relay first** (`node tool/deploy-relay.mjs`, with
  `GHOST_APP_ORIGIN=https://app.gogho.st` in its env), then the apps: a relay from before keeps no removals, and under it
  a removed iPhone or computer only forgets the words and keys, as the release before did. app.gogho.st then needs its
  DNS record and `node tool/deploy-site.mjs --caddy --app build/web-app` (`docs/OPEN_NETWORK.md`, part 6).
- **A saved recording opens in the mixer** (0.11.8, not released; Matt, 2026-11-21: "I'd like to be able to open
  recordings saved from calls in the multi track view with the mixer"). Recordings › a recording › Open in the mixer:
  lib/voice/recording_playback.dart decodes each person's track to 48 kHz mono on the device (ghost/scribe `decode`,
  beside Scribe's own decoders: android Scribe.kt, macos/ios Scribe.swift, windows/runner/speech.cpp), kept under
  recordings/opened/<id>, and the timeline and mixer draw from it through RecordingDesk, which CallRecorder also is. A
  player per voice (media_kit; video_player on the iPhone, which can't go past 0 dB) plays them together, the others
  kept within 50 ms of the first; the meters are read from the samples at the playhead. Save mix makes a new recording
  (CallRecorder.makeMp4, `from` in recordings.json): everyone mixed as the faders stand, each voice as it was.
  integration_test/recording_playback_test.dart on an emulator: opened in 0.6 s, each voice's loudness as made,
  played 2.5 s in step, and the saved mix right with one voice muted and another halved.
- **Calls: the other side's video, relay first, Windows' microphone** (0.11.6; Matt, 2026-11-21: "Video
  is not working on both ends it only shows our local video also the audio device selector doesn't seem to be working,
  connecting over the relay also doesn't seem to be working or the device picker is not working in windows", then
  "Try to negotiate over the relay first"). A received picture arrives in no stream (its sender names none) and was
  added to the sound's received stream, which flutter_webrtc refuses natively ("stream is null" on Android, the Mac
  and Windows) while its Dart list says it took it: every remote tile drew nothing. Received tracks now go into a
  stream made on the device (`_RtcPeer._took`, one at a time), sounds kept apart for their volume
  (integration_test/call_video_test.dart: two calls on one device draw each other at 960x540). The hub's TURN
  server is tried first, alone (`r`), and every path second (`a`), by the side that offered; 15 s without
  connecting counts as failed. Windows' WebRTC takes the microphone from `optional: [{sourceId}]` and reads
  `deviceId` as the speaker, so it was always the first microphone.
- **Unfinished uploads are listed, and can be removed to free their room** (0.11.5, not released; Matt, 2026-11-21:
  "I need a way to see partially uploaded files, the oddysey uploaded partially but then disconnected when I
  restarted the app it stopped uploading but kept the space reserved"). The relay's space info names each blob not
  finished yet (`parts`: id, who started it, size, how much is there, when it last moved; relay/lib/files.dart
  `_info`), and FilesStore.unfinished lists those no transfer on this device holds: another device's, one sent from a
  space's chat (never on the queue on disk), or one from before a reinstall. The Files screen shows each as
  "Unfinished upload" with its bar and Remove for whoever started it, the owner, or a role that may remove it
  (removeUnfinished: DELETE on the blob, the roster shown where needed). An upload the queue does pick up shows what
  the relay has at once and says "Checking it before going on · n%" while a big file is hashed again before more of
  it goes (minutes for a film), where before it sat at nothing and looked stopped.
- **Calls fall back on the relay where no direct way through is found** (0.11.4, not released; Matt, 2026-11-21:
  "Sometimes calls are not negotiating in voice chats and I can't connect to another person, if p2p fails please
  connect over voice through the relay"). Calls had public STUN servers only, so two devices behind strict routers
  (mobile networks, office and hotel Wi-Fi) never connected, and a failed connection was dropped for good. The hub
  now hands whoever joins a room a day's username and password for a TURN server (coturn) beside it
  (relay/lib/turn.dart: coturn's use-auth-secret credentials, `GHOST_TURN_SECRET` and `GHOST_TURN_URLS` in the
  relay's environment; HubCarrier.callRelay). Each connection tries direct and relayed paths at once and takes the
  best; where one still fails, the side that offered starts over once through the relay alone, its offer marked
  `r` (VoiceSession._failed, FallbackMedia in lib/voice/voice.dart; RtcMedia; site/join/voice.js the same). What
  the relay passes is WebRTC's own DTLS-SRTP, keyed between the devices. Off until coturn runs on the box and the
  relay has the secret; with neither, calls are as before.
- **The voice changer, live in space calls** (0.11.1; Matt, 2026-11-20: "I'd like the voice changer to
  work in spaces calles in real time", and ElevenLabs chosen over effects on the device, with its delay). ElevenLabs
  changes whole recordings, so a call goes a phrase at a time: the microphone engine's live mode (native/voicefx,
  `voicefx_live`, `voicefx_take`, `voicefx_feed`, in the capture hook on the phone, Mac and Windows) keeps what is said
  at 16 kHz instead of sending it and plays into the call only what it is fed; `LiveChanger` (lib/voice/live_changer.dart)
  takes it every 100 ms, `PhraseCutter` cuts it at pauses of 550 ms (4 s at most, 250 ms of lead-in, nothing under
  250 ms of speech), each phrase goes as WAV to `VoiceChanger.convertPhrase` (`/v1/voice-changer/<voice>`,
  `output_format=pcm_24000`) and the PCM back is fed in; behind by more than three phrases, the oldest is dropped.
  Nothing is sent while muted; refused, nothing of the voice goes out and `LiveChangerLine` over the call says why,
  with My own voice. Settings › Voice changer › Change my voice in calls, live (off by default). Not heard in a real
  call yet. Tests: live_changer_test, native/voicefx/test/run.sh.
- **The recording's mixer is a full-screen drawer from the banner, not a floating pill** (0.11.1;
  Matt, 2026-11-20: "make the recording plugin banner have a button for "mixer" and have it open a drawer full screen
  with the audio tracks and whatnot instead of the floating pill"). The recording line over the call
  (`RecordingBanner`) has Mixer beside Stop; `showRecordingMixer` opens `RecordingMixerDrawer`, the same timeline and
  mixer (`RecordingTimeline`, `fullScreen`) filling the window, sliding up. Its arrow closes it, and it closes itself a
  moment after the recording ends, so the saved toast shows over the app. `RecordingFloat` and its pill are gone from
  both apps' frames. Tests: recording_float_test.
- **Auto leveler, a plugin that brings everyone in a call to the same loudness** (0.10.8, not released; Matt,
  2026-11-20: "build the auto leveler plugin that levels everyone's voice levels"). `lib/voice/leveler.dart`
  (`LevelerCore`, `AutoLeveler`) and `lib/plugins/auto_leveler.dart` (id `autoleveler`, device or circle). It reads
  how loud each person arrives from WebRTC's own audio level, which is measured before this device's volume, learns
  each voice's speaking level over a few seconds, and turns them toward -22 dB, at most about 9 dB either way. The gain
  multiplies each person's own volume and the output volume in `RtcMedia._apply`; nothing is sent. A person's sheet in
  a call says what it is doing to them. Not heard in a real call yet. Tests: auto_leveler_test.
- **Stickers in Telegram, Signal, WhatsApp and Matrix chats stand on their own** (0.10.7, not released; Matt,
  2026-11-20: "stickers in telegram chat and others render inside chat bubbles instead of transparent backgrounds when
  sent and when recieved"). A sticker is its own kind of picture (`InboxMedia` kind `sticker`), drawn at most 9rem a
  side with nothing behind its see-through parts and no bubble round it (`InboxSticker`, `isStickerAlone`); a sticker
  with words or a quote keeps its bubble. Each network says which are stickers: Telegram's `messageSticker`,
  WhatsApp's pointer kind, Matrix's `m.sticker`, and Signal's helper marks its sticker attachment (`"sticker": true`,
  sidecar/signal). One of Uplink's own stickers goes to Telegram as a Telegram sticker where it is WEBP (a PNG one goes
  as a picture), and to the others as a picture shown here as a sticker.
- **Reactions in spaces and circles** (0.10.6, not released; Matt, 2026-11-20: "add reactions after done to spaces and
  circles"). Press and hold (or right-click) a message in a space's or a circle's chat: the reaction row from texts
  (`reactionChoices`, `ReactionPickRow`) sits over its menu. A space's bubbles wear them as stickers, as texts do
  (`ReactionStickers`); a circle channel's lines have pills under them, each emoji with how many gave it, yours ringed,
  pressed to put yours on or take it off, and a + for another (`ReactionChips`). Each person's each emoji on a message
  is on or off with when it was said, the newest word winning (`lib/voice/space_reactions.dart`), so it ends the same
  on every device whatever order the words come in; one person's phone and computer count once. Said in the room as
  `react`, kept by the hub for devices that were away, and handed over with the history (`reacts`); kept on the device
  beside the polls' votes.
  - **In read-only spaces everyone may react**: only posting is the admins'. The relay takes reactions as a packet
    kind of their own (`toRoomReaction`, 4: kept, to everyone, at most 512 bytes), which a reader in a read-only room
    may send, and passes them on with that first byte, so the apps take nothing but a reaction from one: the hub still
    refuses a reader's words and an app still drops them. A relay from before (until this one is deployed) doesn't say
    `react` in its hello; the apps then send reactions as ordinary kept packets, which work everywhere but a read-only
    space, where that relay refuses a reader's.
  - Tests: space_reactions_test (pictures `test/shots/space-reactions-*`), relay read_only_rooms_test.
- **Welcome messages, a welcome space and read-only spaces** (0.10.6, not released; Matt, 2026-11-20: "add - Welcome
  messages for new members and allow setting a "welcome" channel as well as read only channels for system messages
  and admin / moderation announcements"). Circle settings › Welcome, for whoever may change the circle
  (`lib/ui/circles/circle_welcome.dart`, `lib/circles/welcome.dart`):
  - **Welcome message and welcome space**, kept in the circle's signed manifest (`wl`: the words, and the space's seed).
    A newcomer's app opens the circle on the welcome space (on a phone too, as soon as a link's circle has its
    manifest: `AppShell.openCircle(land: true)`), and that space's chat starts with the welcome as a card, "{name}"
    in it being whoever reads it. Nothing is sent: every app draws it from the manifest, so it is there for someone
    who joined while the admins were away. A wide window opens a circle on its welcome space too.
  - **Read-only spaces**: Space settings › Read-only (`rdo` in the space's entry). Only the owner and the admins (whom
    the owner granted, as every role that can change the circle, its spaces or its roles makes its holder) post
    there; everyone else sees "Only admins can post in # …" in the box's place, and an admin sees a line saying
    everyone else reads. Held three ways: the box isn't offered; every member's app drops anyone else's words, edits,
    votes and passed-on history there (`HangoutRoom.mayPost`); and the relay itself holds them to it. A read-only
    space's chat is a room of its own on the relay whose name is made from 16 bytes of the space's seed and the
    circle owner's public key (`readOnlyRoomOf`, relay `Hub.anchoredName`), joined with what makes the name and the
    circle's owner-signed admin list (`ro` in the join, `anchor` when the list changes), so the hub can check whose
    room it is: it refuses to keep anything from anyone else (`{"ro": "refused"}`) and passes what else they say
    (who they are, asking for history) to the owner and admins alone, so a changed app can't put words in front of
    the other members. Read-only rooms are apart from ordinary rooms of the same name, and messages stay on the device
    under the space's own room, so a space made read-only (or opened again) keeps what was said in it; what the hub
    kept for the old room for others' closed phones is not carried over. An older app sees the space as an ordinary
    one in the old room, which current apps have left.
  - **System space**: a read-only space where each member's app writes, for that member, the circle's comings and
    goings as they are heard: who joined (from the joins the circle's room carries), who was kicked or banned, who became or
    stopped being an admin (from the manifest's changes), as small lines among the admins' announcements
    (`CircleSystemNote`, kept on the device as `circles_system`, 200 to a circle). Chosen in Circle settings ›
    Welcome; it becomes read-only as it is chosen, and stops being the system space if opened again.
  - Not drawn in the Dial-Up look's transcript, whose chat is its own. Needs the relay deployed for the hub's half; a
    relay from before takes `ro` as an ordinary join (everything still works, held by the apps alone).
  - Tests: circle_welcome_test, circle_welcome_screens_test (pictures `test/shots/circle-welcome-*`), relay
    read_only_rooms_test.
- **The Marketplace, and plugins from other developers** (not released; `lib/plugins/pack/`, `lib/market/`,
  `lib/ui/market/`, `relay/lib/market.dart`; Matt, 2026-11-20: "This is a lengthly feature request, I would like users
  to be able to develop and submit their own plugins to our plugin marketplace and I'd like to be able to verify them for
  the store through a review process. Please include documents on how users can develop plugins, please add a developer
  setting for users to be able to manually upload plugins for development testing and a listing process. Move plugins
  out of settings into a marketplace button on the navigation rail with a marketplace icon. Add a submission area with a
  form to accept an icon, description, plugin tags, etc"). A plugin from another developer is a pack: one
  `<id>.ghostplugin` file of JSON in the format `ghost-plugin/1`, its manifest, rules and icon and nothing that runs,
  compiled into the extension points the built-ins use (`lib/plugins/pack/`: `manifest.dart` checks it, `phrases.dart`
  finds words with phrases and bounded tokens in place of regular expressions, `pack_plugin.dart` runs it through
  `gated_host.dart`, `installed.dart` keeps what is installed in the app's `plugins` folder and checks it again at every
  start). A pack sees only one-to-one texts from numbers not in the contacts, not encrypted, and never acts on one with a
  sign-in code. Its switch is `plugin_x<id>`, and the indexes `plugins_store`, `plugins_dev`, `plugins_floor` (the
  highest version ever installed, so no older one comes back) and `plugins_paused` (a pack too slow five times in ten
  minutes). The store is `/market` on the relay (`relay/lib/market.dart`, `market_pack.dart`, `market_store.dart`):
  requests signed with the hub key over `ghost-market v1` words, every check made before a body is read, submissions,
  the review queue, reports, a daily sweep and `GHOST_MARKET_*` limits. Matt reviews in Settings › Admin › Plugin review:
  an approval is his key's signature over `ghost-market approve v1`, the id, the version and the package's SHA-256,
  checked against `marketReviewKeys` (empty until he gives his key) when a plugin is added and at every start;
  `ghost-market revoke v1` withdraws a version, with its reason signed, and `ghost-market retire v1` retires a key.
  Plugins left Settings for a Marketplace ring (`Lucide.store`) between Archive and Settings on the rail, the dock and
  Dial-Up's taskbar ("Market"): Discover, Added, Updates, Submit a plugin (the plugin, its icon, description, category,
  colour, tags, screenshots and notes; `lib/ui/market/submit_screen.dart`), My submissions and the review queue.
  Settings › Developer › Plugins in development loads one from a file, the clipboard or a link, with Reload and Try it,
  and the API has `plugins.devInstall` and `plugins.devRemove`. Nothing from other developers on iPhone. Docs: "Build a
  plugin" on gogho.st/docs (`docs-src/pages/build-a-plugin.html` and eight more), `docs/marketplace.md` for whoever
  maintains it, and two example packs in `examples/plugins/`. Tests: pack_canonical_test, pack_phrases_test,
  pack_format_test, pack_plugin_test, pack_registry_test, pack_review_test, pack_words_test, pack_installed_test,
  pack_examples_test, api_plugins_dev_test, marketplace_test, market_discover_test, market_submit_test,
  market_mine_test, market_review_test, market_state_test, dev_plugins_settings_test, docs_slugs_test, and the relay's
  market_pack_test, market_test, market_config_test and handles_test.
- **Souls, special badges and the admin page** (0.9.36, not released; Matt, 2026-11-19: "Build a new points system into
  the app called souls ... display the points in the top bar next to the feedback button with a flame icon ... a simple
  admin page for me to login to ... only my matt account ... see all users who signed up on the relay and issue special
  badges and souls"). The relay keeps each install's souls, its special badges and a log of what was given
  (relay/lib/handles.dart: `souls?`, `admin-*`, `specialBadges`), and now the usernames themselves for the admin list
  (`_shown`, from each claim and each hello; before, only their hashes). The count with its flame is beside Share
  feedback (`lib/ui/souls.dart`, `SoulsChip`; on the Mac in the title strip), told as souls are given. Badges show
  beside names where the verified badge does and by name on profile cards (`lib/ui/special_badges.dart`), told with the
  verified answer. Settings › Admin (`lib/ui/admin_page.dart`), in developer mode for @matt only: signed in with a
  username and password made by `tool/admin-password.mjs` (the relay keeps the password's salted, 100 000-times SHA-256
  hash: GHOST_ADMIN_USER, GHOST_ADMIN_HASH; GHOST_ADMIN_NAMES says which accounts may try, `matt`), five tries an
  hour, signed in only while connected. Tests: souls_test, relay handles_test.
- **An emoji picker of the app's own; Blocked beside Add** (not released; Matt, 2026-11-19: "roll an in house emoji
  picker we should be able to pull the code out from other apps we've built", "move blocked to the right of the add
  friend button"). Ghost Keyboard's emoji data and search ported (`lib/emoji_data.dart`, `assets/emoji/emoji.tsv`,
  emojibase MIT; Emoji 15.0 and older, so nothing draws as a box), in a sheet like the sticker sheet
  (`lib/ui/emoji_picker.dart`): search by name, keyword or shortcode, a skin tone, a tab per group with Recent first.
  It stays up while emoji are picked into the box at the cursor; every composer's Emoji opens it in place of the
  computer's own panel. Contacts' Blocked is a round button beside Add, not a row. Tests: emoji_picker_test.
- **Plugins' messages as cards** (0.9.33, not released; Matt, 2026-11-19: "use icons for starting and stopping
  recording and allow plugins to render messages like these as cards with iconography and details"). A space's
  message may carry a plugin's note (`lib/voice/plugin_note.dart`, `pn`: plugin id, kind, short details) beside its
  words, which older builds, the browser page and previews show. `GhostPlugin.card` makes a `PluginChatCard` of it
  (icon on the plugin's hue or on red, title, line, facts with icons), drawn by `lib/ui/plugin_note_card.dart` in
  place of the words in every chat look. Record call's started and stopped are the first. Tests: plugin_cards_test.
- **Sign up with Discord, Telegram or Signal** (0.9.31, not released; Matt, 2026-11-19: "add a sign up with discord
  sign up with telegram or signal option where it pre populates your connection, loads your picture and username and
  status"). `lib/ui/sign_up_from.dart`, on the welcome and on Settings › Me › Profile until a username is claimed.
  Discord: the relay's OAuth sign-in (relay/lib/handles.dart), which links it as Settings › Me does and hands the
  install `about` (name, picture address) as it signs in, never kept. Telegram and Signal: connected as Settings ›
  Networks connects them, then `InboxNetwork.ownProfile`. The form is filled; nothing is claimed or sent until
  Continue. Signal's own profile is read with the sidecar's `who` for this account's ACI (not yet tried on a real
  account). Tests: sign_up_from_test, relay handles_test.
- **Joins told of; a circle's link that brings the app with it** (0.9.27, not released; Matt, 2026-11-19: "add join
  notifications for memebers in circles", and "make a route to allow people to click a link on their phone or desktop
  to join a circle, have it prompt them to download the app if it's not downloaded already and then have it redirect to
  the circle after they sign up for their account").
  - Coming into a circle, a device says so once in its room (`joined`, with its name and when), kept by the hub for
    whoever is away. Every other member is told of a join after their own, once per person whichever of their devices
    said it (`circles_joins`), unless it is days old: a notification on a phone in the background (`circle:<seed>`,
    which opens the circle), a toast with Open in the app. Settings › Notifications › Joins in circles turns it off.
    Joins also name people in the members list.
  - site/join, for a circle's link: the download for the device it is opened on (Android, Mac, Windows; the home page
    otherwise) and three steps. Get the app copies the invite; the app reads the clipboard once, on a new install's
    first setup with no circles yet, and joins and opens the circle (`lib/circles/pending_link.dart`). Open in Uplink
    opens `ghostmsg://join/#c.…`, which the Android app (MainActivity), the Mac's (CFBundleURLTypes,
    AppDelegate) and Windows' (`windows/runner/links.cpp`: the scheme registered for the user at each start; a second
    copy hands the link to the running one by WM_COPYDATA) take, on "ghost_desktop/links" (`lib/desktop/links.dart`).
    A link opened while the app is still being set up is held and opened once it is.
  - Tests: circle_joins_test.
- **Voice changer, a plugin: voice messages in another voice, by ElevenLabs** (0.10.8, not released; Matt, 2026-11-20:
  "I want it to have the same vocal queues as the speaker not just transcribe and re speak what they say"; "build it as
  a plugin"). `lib/voice/voice_changer.dart` sends a finished recording to ElevenLabs' Voice Changer
  (`POST /v1/voice-changer/{voice}`, `eleven_multilingual_sts_v2`, back as `mp3_44100_64`), which is speech to speech:
  the delivery is kept, the voice swapped. The person's own key and a voice from their own account's list
  (`GET /v2/voices`), kept in one 0600 file (`voicechanger/elevenlabs.json`), never among the app's choices and never
  shown again. Hooked where a space's chat and a network's chat finish a voice message (`VoiceChanger.forSending`); a
  recording that could not be changed is never sent as it was. Signal, WhatsApp, Matrix and the account helpers say an
  MP3 is one. Pages: `lib/ui/voice_changer_ui.dart`; plugin `voicechanger` (`lib/plugins/voice_changer.dart`), device
  only, with a section of its own in Settings.
  - Tests: voice_changer_test, against a server standing in for ElevenLabs (pictures voice-changer-*).
  - Not yet: tried with a real ElevenLabs key (the paths and fields are from their reference, read 2026-11-20). Not
    in ordinary texts (the phone sends those itself, `voiceSend`), not in calls (ElevenLabs wants the whole recording),
    and only where voice messages are recorded: an Android phone.
- **Soundboard, a plugin for calls and whole circles** (0.10.8, not released; Matt, 2026-11-20: "build a soundboards
  plugin for circles"). Pads in a call (`lib/ui/soundboard_screen.dart`, from the call's menu and the space's header)
  that play a short sound on every device in it (`lib/voice/soundboard.dart`, `lib/plugins/soundboard.dart`). No sound
  is sent: the pad's id is said in the call's room (`sb`), and each device plays its own copy through the app's player
  (`VideoEngine`), at a loudness of its own or not at all (`soundboard_volume`, `soundboard_quiet`); nothing while
  deafened; no more than six from one person in ten seconds; ten seconds at most. Twelve sounds of the app's own
  (`assets/soundboard/`, synthesized by `tool/soundboard_sounds.py`, nothing recorded). A circle's own, up to 16 clips
  of 1 MB, added by whoever may change it: each sealed where the circle's banner is kept (`Circle.bannerChannel`) and
  named with its key in the signed manifest (`pl.soundboard.snd`), so a device plays only what its own list has, never
  a file someone names in a call. A line over the call says who played what.
  - Tests: soundboard_test (pictures soundboard-*).
  - Not yet: heard on a device. The app's sounds have not been listened to by anyone, and nothing has been played in a
    real call (in particular an Android phone in a call, whose sound goes through the call's own audio mode). A removed
    clip's sealed file stays on the relay.
- **Plugins for whole circles: Record call, Scribe, Live captions, Watch together, and SMS spaces** (0.9.21, not
  released; Matt, 2026-11-19: "Start with the recording plugin, then scribe, then a special space in the circle called a
  "SMS Space" to text members, Live captions, and watch together"; "Some plugins should be serverside / cirlce side as
  well"). A plugin says where it may be on (`PluginScope`: this device, a whole circle, the server); a circle's owner or
  an admin turns one on for everyone in Circle settings › Plugins, kept in the circle's signed manifest (`pl`). Calls
  have places for plugins: the call's menu in every design (`Slots.callControls`) and lines over the call
  (`Slots.callBanner`). Server plugins are a scope only so far: nothing runs on the relay yet.
  - **Record call** (`lib/voice/recorder.dart`, android `CallRecorder.kt`, macos/ios `CallRecorder.swift`,
    `lib/voice/mp4_names.dart`): one MP4, track 1 everyone mixed (the default), then one AAC track per voice, named
    (`udta/name`, `udta/©nam`, the handler's name). Each other person's decoded sound is tapped natively
    (`AudioTrack.addSink`, `RTCAudioTrack.addRenderer`), this device's own after VoiceFx, each to its own file held to
    the clock, encoded and joined at the end. Everyone is told by a red line over the call whatever their plugins, and
    asked; only voices whose own device said yes (`ry` in the call's `me`) are in it. Recordings stay on the device
    (Recordings: play with a track per voice, share, save, send to the space). Not on Windows.
  - **Scribe** (`lib/voice/scribe.dart`, android `Scribe.kt`, macos/ios `Scribe.swift`): a recording written out by
    the device's own speech recognition, each voice's track on its own, cut at pauses, lines named and timed; a line
    summing it up on a phone with its model; kept as `.txt` and as `.srt` subtitles the player shows. Android 13+.
  - **Live captions** (`lib/voice/captions.dart`, android `LiveCaptions.kt`, macos/ios `LiveCaptions.swift`): each
    device writes out its own voice while anyone in the call wants captions (`cw`), and says the words in the call's
    room (`cap`); others' lines are translated where Translate is added.
  - **Watch together** (`lib/voice/watch_together.dart`): a Files-space video or song played on everyone's device in a
    call from its own sealed copy; play, pause and where it is said in the call (`wt`), a player more than 1.5 s out
    moved.
  - **SMS spaces** (`lib/circles/sms_space.dart`, `lib/ui/sms_space_ui.dart`): a circle's texting space whose people
    without the app are in it by text from one member's phone (`CircleSpace.extra.sms.by`); their numbers kept on that
    phone alone; messages out as "Name: words", replies in marked 📱, STOP takes someone out.
  - Checked: two-member protocol tests for each; on an emulator, a four-track MP4 read by ffprobe and Scribe writing out a
    two-voice recording; the Mac's encoder on its own. Not yet: a real call between two devices recording, captions or
    watching; real texts through an SMS space.
- **Signal: group names, and sends that say why they stall** (0.7.42, not released; `sidecar/signal/main.go`,
  `lib/inbox/signal.dart`; Matt, 2026-11-16: "Sending signal messages get stuck on sending... and the group titles
  are not coming through", then "It says bad state signal took too long to answer").
  - Group names: the app asked for groups once, on linking, when the helper's store has none (a group is known only
    from its first message, which carries its key), so every group stayed "Signal group". The helper now looks a
    group up the first time a message from it arrives and says a `group` event (title, members, picture); the app
    also asks for groups again when the connection comes back, at most once a minute.
  - Sends: the app waited 30 s for a send while the helper allowed itself 90, so the app gave up first and the
    message sat on sending with "took too long". The helper now gives a send 60 s and the app waits 75, so the
    helper's own error arrives and the message is marked failed with it. The helper logs each request and each send's
    stages with their times to `signal.log` beside its store and to standard error, which the app now passes to the
    Developer log (its own lines and signalmeow's warnings only; no message's words). Why Signal itself is slow to
    take a message is not known yet: the next stuck send says where in that log.
- **Files-space videos stream as they play** (0.9.10; `lib/files/file_stream.dart`; Matt, 2026-11-18: "do we need to
  download the whole file to play? would it be possible to setup streaming and buffering of the file?", then "yes build
  it"). A video or audio file in a Files space plays from a server on the device (127.0.0.1, a random port, a 128-bit
  token in the address) that answers byte ranges by fetching only the sealed chunks needed, decrypting and checking each
  on the device, and reading 8 MB ahead. Chunks are kept as they come; once all are in, they become the normal download,
  checked by SHA-256. Other partial caches are held to 1 GiB and 14 days. The scrubber shows what is loaded; a spinner only
  while stalled; nothing spins past 20 s (it says why, with Open with another app, which downloads the rest with its
  progress). Android allows cleartext to 127.0.0.1 alone. Tests: files_stream_test, video_stream_screen_test.
- **MKV and MP4 in the app's own player, everywhere** (0.9.8; `lib/ui/video_engine.dart`, `lib/ui/video_screen.dart`;
  Matt, 2026-11-18: "add support for playing mkv video files and mp4's within the app in a player themed by glacier UI").
  A computer plays videos inside the app now, in the same Glacier player as the phone, by media_kit (libmpv: MKV, WebM,
  HEVC, AV1 ...; LGPL builds on the Mac), in place of the window of its own it had (DeskVideo.swift keeps only the poster and
  the temp folder). The phone stays on ExoPlayer, which reads Matroska. An iPhone plays MP4 and MOV but not MKV (it says
  so). On a computer: space, arrows, M, F for full screen, Esc, a volume slider, a mouse scrubber; a file nothing here can
  play says so, with Open with another app. The Mac and iPhone builds use CocoaPods now (media_kit has no Swift Package
  Manager support): `pod install` is part of a build. About 23 MB more on the Mac. Tests: video_controls_test.
- **Uplink accounts: recovery words, an Ethereum-style address, a password and the number** (0.9.4–0.9.5; `lib/account/`,
  `lib/ui/account_screens.dart`, `relay/lib/accounts.dart`; Matt, 2026-11-17: "We need to have a way to login to existing
  accounts. We might need to add password based authentication as well as SMS verification for verified numbers", and
  "i also want accounts to be generated based on ethereum type addresses with a recovery seed we can back up"). Creating
  an account makes 12 BIP-39 words; from them a secp256k1 key at m/44'/60'/0'/0/0 and its EIP-55 address (the account's
  id), and the Uplink identity (HKDF). An install that already had an identity keeps it, bound to the address. A backup
  sealed twice (Argon2id of the password, 64 MiB/3; and a key from the words; AES-256-GCM, the address bound in) is kept
  on the relay, which never sees either. Signing in: username + password (the relay hands the copy over only on a proof
  from the password, 10 tries an hour per account, plus a texted code where the account has a verified number), or the
  recovery words alone. Every device signed in is the same identity at once (below). Tests: account_crypto_test
  (BIP-39/32, EIP-55, HKDF, Argon2id vectors), account_flow_test, relay accounts_test.
- **Profiles: a picture, a status, and a card behind every "@"** (0.9.21, not released; Matt, 2026-11-19: "build a
  profile section in the app that allows us to set profile pictures and status messages, when clicking on a @mention
  anywhere including signal and telegram chats show this profile popup with actions available for the user in context
  of where it's placed when using telegram and other outside apps we should proxy through any profile information their
  APIs make available and in app it should have a small input to send a DM to a user").
  - Settings › Me › Profile has a picture (square and small, made as a circle's is: `pickCirclePicture`) and a status
    line (80 characters). Both go to friends with the name and line (`p`, `st` in the profile; a build from before
    passes over them). In a space the greeting says the status and a mark of the picture (`ph`); the picture itself is
    asked of its owner when someone opens their card (`pic?` / `pic`), so greetings stay small (lib/me/pictures.dart).
  - Pressing an "@" opens the person's card (lib/ui/profile_card.dart, `showProfile`): picture, name, username, status
    and line, then what can be done from there. In a space: mention them back and the members. On Uplink: open the chat,
    add them as a friend or answer their request, copy the username, and for a friend a field to write to them without
    leaving the page. In a text or an Uplink chat an "@username" written in the words is pressable too (`handleMentions`).
  - Telegram and Signal: mentions come through (Telegram's text entities; Signal's mention ranges, whose placeholder
    becomes "@Name"), and the card shows what their APIs give (`InboxNetwork.profileOf`): Telegram's name, username,
    bio, photo, emoji status and last seen; Signal's name, number, avatar and about line. Message them there, copy the
    username. The Signal helper (sidecar/signal) sends the mentions and the about line; the next release builds it.
  - Tests: profile_card_test, inbox_mentions_telegram_test, inbox_mentions_signal_test, sidecar main_test.
- **Pictures full screen** (0.9.25, not released; Matt, 2026-11-19: "when clicking a picture in a chat, like in a circle
  make it a full screen overlay"): a picture or GIF in a space's or circle's chat, and a Telegram or Signal photo, opens
  over everything on a dark ground (lib/ui/picture_overlay.dart): its small picture at once and the file as it comes,
  pinched or scrolled to zoom, a tap, Escape or the cross to go back, and … for the file's own page (Save, Share).
  Tests: space_chat_files_test.
- **Removing someone from a circle; every member's card** (0.9.24, not released; Matt, 2026-11-19: "add the ability to
  remove members from a circle as an admin", then "clicking on a member in the member list should also show the users
  profile popup with linked numbers, and other details in addition to things like changing the role").
  - The owner removes anyone but themselves, an admin anyone but the owner and admins (`CircleManifest.mayRemove`); an
    admin removed stops being one. It is said in the circle's signed manifest (`rm`), so every member's app leaves them
    out: not listed, not heard in its spaces or calls. Their own app leaves the circle, says "You were removed from …",
    and leaves again if they come back by its link. Let back from the same card. A build from before knows nothing of
    it, and anyone keeping the circle's link and an older app could still read it: a removal is not a new key.
  - Pressing a member opens their profile card, with their roles and whether they are on, then the circle's actions as
    this device may take them: give or take away each role, make or stop an admin (the owner), remove.
  - A profile can show friends its number and linked accounts (Settings › Me › Profile, off until switched on); the card
    lists them, with Text and Message on the network where it is linked here.
  - A circle's banner (Matt, 2026-11-19: "make circles have a background image for the header like discord does and make
    the circle profile picture larger"): a wide picture, three by one, chosen in Circle settings › Overview, across the
    top of its sidebar (`bn` in the manifest, at most 26,000 characters so it still goes in one packet with the
    picture); a circle without one shows a wash of its colour there. The picture beside its name is larger, and its
    spaces a step smaller again ("make the spaces slightly smaller still in the sidebar on circles").
  - Tests: circle_remove_test.
- **One identity on every device, in circles and spaces too** (0.9.20, not released; Matt, 2026-11-19: "when i join a
  server on my other logged in machines it's joining as a new matt every time instead of reusing my existing keys and
  owner account, when I login on ghost i should have the same identity across all devices"). Every computer paired with
  a phone was in each circle and space under a key made for it alone (`voice_key`), even after taking on the phone's
  identity or signing in, so each was another Matt and never the owner.
  - Spaces, circles and Files spaces ride the install's own hub connection under its identity wherever it has one
    (`Voice.separateKey`: only a paired computer that has not yet taken on the phone's identity keeps a key of its own).
  - A call moves to the device that comes in last, as Discord does: it says `moved` on joining, another device of the
    same identity leaves, and everyone else lets go of the connection they had and takes the new one's offer.
  - A space's chat no longer counts one's other device as someone here, and greets a person's second device (`hi`
    with `q`), which the relay announces to nobody.
  - What an old key made or was is carried over once (`Voice.carryOver`): a paired computer's `voice_key`, and the
    identity an install had before signing in (`was_key`, kept beside the account's words). That key makes the identity
    an admin of every circle and space it owns, and says in each circle's room, signed, that its id is the identity's
    (`was`, kept by the hub); every device then lists the two as one person (`Circles.sameAs`).
  - A circle known only by its link is never signed over. Choices are written before the app starts again (a paired
    computer's sign-in came back signed out, its last choices lost as it closed), and a sign-in cut short that way is
    taken up again at the next start from the words in the vault (`Account.resume`). The start-of-day check with the
    relay waits for the hub, which it never reached before, and sealing the backup again keeps what another device put
    in it. A paired computer takes the phone's username and name where it has none.
  - Tests: one_identity_test (a stand-in relay with several devices of one identity). Not seen on real devices yet.
- **Circles grown up: invites, a circle's dock, members, inviting contacts by text** (0.9.4–0.9.5; Matt, 2026-11-17:
  "Finish the missing pieces", then a run of asks the same evening). Circle invites wait for Join (a banner, a card on
  the Circles tab, Not now / Invites); gogho.st/join opens in the Android app (App Links, site/.well-known/assetlinks.json).
  The Circles tab lists only circles. A circle's dock while it is open: Home, Spaces, Members, New space, Settings;
  the main dock's places close a circle first; leaving a circle's call lands back in the circle. Members is a drawer
  with Add people at its top; circle settings sit beside Add people. Add people suggests friends first, then contacts,
  and texts those not on Uplink (after a confirm showing the words); the invite waits on the relay (`/invites`, sealed by
  a key from their number, 30 days) until they verify that number. A space's header has its kind, name and a signed
  description (`about`). Contacts have a Friends filter. The gap under the composer matches the dock's. Dial-Up's
  sidebar is wrapped in its bevel (no teal strip). Files: entries signed by their author and chained, moderator
  deletes free the blob (owner-signed roster), uploads checked before the body, every relay limit set by env. The Mac
  has its own title bar back for now (MacChrome.own). Plugins head Settings. A call's minimise is a back arrow.
  Tests: circles_invites, circle_dock, circle_call_leave, circles_tab, contacts_friends, invite_people, space_about,
  files_space_signed, files_space_share_in, relay invites_test and files_hardening_test.
- **Circles, and Files spaces** (0.9.2; `lib/circles/`, `lib/ui/circles/`, `lib/files/`, `lib/ui/files_space/`,
  `lib/net/file_seal.dart`, `relay/lib/files.dart`; Matt, 2026-11-17: "remove all of the code related to the server UIs and
  make a new design ... with it's own sidebar full of spaces each space should be able to act as a chat and a voice chat,
  or just a texting space. Additionally add full functionality for filesharing in a space when the space is designated
  a Files Space", then "Lets remove the other views and focus on the list view"). The server preview and the Servers tab
  are gone; the Circles tab is in their place, with spaces outside circles, space groups and linked Discord servers
  under the circles. A circle has a name, colour, icon and picture, and a list of spaces under headings, each one of
  three kinds (`k`: chat and voice, text, Files). The list is an owner-signed manifest (admins the owner grants may sign;
  an owner-signed generation makes removing an admin final) gossiped sealed in the circle's own hub room; links are
  `gogho.st/join/#c.<seed>...`. A Files space keeps its files on the relay (`/files/`), each sealed end to end in 256 KiB
  AES-GCM chunks with a key of its own and described in a sealed op log, so the relay sees only blobs and sizes: upload
  with progress and resume, list and grid, folders, search and sort, previews (pictures, video, audio, text, PDF by the
  system), save, share, rename, move, delete; drag and drop on the Mac, share into it from Android. Programs are never
  opened from the app. Relay limits: a file 2 GB, a space and the store by quota, per-address limits, reservations
  released after 10 minutes. Tests: circles_test, circles_trust_test, circle_list_test, circles_screens_test,
  files_space_test, files_space_screen_test, relay files_test and files_limits_test.
- **A down arrow to the newest message, and each chat keeps its place** (0.9.2; `lib/ui/jump_to_latest.dart`;
  Matt, 2026-11-17: "add a down arrow that pops up when we enter a chat and we're not scrolled to the bottom or after we
  scroll up a certain amount, remember the scroll position when switching between chats"). In texts, Telegram and
  Signal chats and a space's chat, a round arrow (a bevelled square in Dial-Up) shows above the composer once you are
  more than a screen (at least 400 px) up, or when a chat opens at a kept spot, with a red count of messages written
  since; pressing it goes to the newest. Each chat keeps where it was for the session (`sms:`, `inbox:<network>:`,
  `space:` keys) and opens there again; a spot kept at another width, look or text size is dropped and the chat opens
  at the newest. Tests: jump_to_latest_test (11), themes_test screens.
- **Translate, and a Plugins page like a market** (0.8.10; `lib/plugins/translate.dart`, `translate_host.dart`,
  `shown_store.dart`, `lib/ui/translated_card.dart`, android `Translate.kt`, `lib/ui/plugins_page/`; Matt, 2026-11-17: "add a
  translate plugin which can automatically translate texts when detected from another language and show the original
  text dimmed in a card with the translated text for the actual message bubble also redo how the plugins look with their
  own dedicated plugins page with a marketplace like look how ghostmd has"). Translate (off until added) tells a text's
  language and translates it on the phone with Google's on-device ML Kit (language-id 17.0.6, translate 17.0.3): the
  bubble holds the translation and a dimmed card above it the words as sent, "Translated from Spanish · Show original";
  in Dial-Up the original is a dim line under the translated one. Never your own messages, codes, links or a word or two.
  Each language's model (about 30 MB) is downloaded once, on Wi-Fi unless chosen otherwise ("Getting Portuguese
  ready..."). Texts, Telegram, Signal and spaces; a paired computer asks the phone over the desk link (`translate`); an
  iPhone says it is unavailable. Its choices: your language, automatic or from the message menu, Wi-Fi only, downloaded
  languages. A fifth extension point in the plugin contract carries it (`TextRule`, `ShownText`, `TextHost`). The Plugins
  page replaces Settings › Plugins, after Ghost.md's Market: a band in colour with the plugins' tiles, search, chips,
  Featured, a card each with Add or Added, and a page for each plugin (what it does, what it reads, its settings).
  Translations are kept in memory only, not on disk. Tests: plugins/translate_test, plugins_page_test, themes_test
  screens. Not tried on a phone; the whole suite was not run.
- **The app is Uplink** (0.12.51; Matt, 2026-11-27: "Update all the language in the app to replace ghost and ghost
  messaging with Uplink we're going to push it to the Satellite-im/uplink repo", then "when you're done also update the
  logo to the uplink logo on the desktop and deploy to all platforms"). Every word someone reads says Uplink: the
  app's strings and its 27 translations, each platform's own half (the name under the icon, window titles,
  notifications, what the system asks permission with), the relay's and the Discord bot's messages, the browser
  extension, the site and the docs, and the comments. The Mac app is `Uplink.app` and the Start menu's entry is
  Uplink. **What keeps its old name**, because a program or an install depends on it and nobody reads it:
  identifiers and file names in the source (`GhostLogo`, `ghost_messaging`, `ghost-mark.png`), the package and
  bundle ids, gogho.st, the `ghostmsg:` scheme, `.ghostplugin` and `.ghostlook`, every wire constant, the files
  server's `Authorization: Ghost <token>`, a file card's `Ghost file: ` mark, the relay's greeting
  `Ghost Messaging relay` (an app of any version looks for it), Windows' install folder and `ghost_messaging.exe`
  (an install is found there by its own update), Linux's `ghost-messaging` command and package, and every platform's
  data folder, so nobody's messages move. A Mac copy installed before keeps its file's name, and so its name in
  Finder and the Dock, until it is renamed: the updater swaps the new app into wherever the running one is
  (`macos/Runner/UpdatesChannel.swift`). Still saying Ghost on purpose: the walkthrough's recorded voice
  (`lib/onboarding/narration.dart`), the sticker pack of ghosts and the Ghost Ring decoration, and other products
  (Ghost.md, Ghost Keyboard). **The icon** is `art/app-icon.png`, Matt's `UplinkLogo.png`, and
  `python3 tool/app_icon.py` writes every platform's from it, Windows', Linux's, the iPhone's and the extension's
  now too; the picture is cleaned first, and the tool refuses one a round home-screen mask would cut.
- **A circle's picture and banner: positioned, sharp, and sent whole** (0.12.52; `lib/ui/circles/circle_picture.dart`,
  `lib/me/picture_make.dart`, `lib/ui/circles/circle_face.dart`, `lib/circles/circle.dart`; Matt, 2026-11-27: "uploading
  the banner from my desktop to AlphaTesters circle says 'cannot use image'", then "uploading the pictures for banners
  and the circle profile picture should use a cropping / zooming tool and upload at full resolution, right now they're
  super low resolution"). Both are chosen, then positioned under the window a profile picture has
  (`lib/ui/picture_crop.dart`: round for the picture, three to one for the banner), and kept as two things. The
  stand-in in the circle's manifest is a JPEG now (a PNG where the part chosen can be seen through, so a logo keeps its
  ground): 256 pixels across for a picture and 480 for a banner, where a PNG in the same room came out 72 to 128 and 150
  to 192 for anything with detail in it. The part chosen is cut at the picture's own resolution (up to 2048 across for a
  picture, 3840 for a banner; never made larger than it is), goes up sealed under the circle's own seed, and is named in
  the manifest: `bf` as before, and `pf` for the picture, which says which stand-in it is the whole of, so one passed on
  by an older build after it changed the picture is not drawn for the new one. A face drawn with more than 160 pixels
  uses the full picture once it is on the device (`CircleFulls`); the banner already did. **What goes up is a copy the
  app makes**: until now a banner set from a computer sent the chosen file itself as one of the app's own, and the
  upload moved the person's picture out of its folder into the app's cache. **Each failure has its own words**, with
  what the device or the relay said: a file that is no picture (named), a full copy that didn't go up (the stand-in is
  still set), a circle this device can't change or that has no room left (tried again with a lighter stand-in first),
  and an upload still waiting after two minutes is let go. Tests: circle_picture_test (the makers on pictures full of
  detail, the part chosen, a logo's ground, the cut's size; `pf` through edits and an older build; the whole of
  choosing a banner and a picture on a computer with the chosen file left as it was; each refusal's words). The
  refusal Matt met was not found: both pictures on his Desktop pass the old maker and the new, and his circle's
  manifest had room, so it failed at a later step the old message did not name. Run for real on the emulator against
  a relay on this machine: a new circle's picture positioned and drawn, then its banner and its picture set from the
  circle's settings, each with its cut on the relay and in the app's cache at the picture's own size (3000 by 1000,
  2000 by 2000) and no temporary file left behind; and with the relay stopped, a banner set from its stand-in once
  the two minutes were up. Not tried on a Mac, which is where he met the refusal, nor on an iPhone.
- **Looks and their packs** (0.12.50; `lib/looks.dart`, `lib/app_state.dart`, `lib/packs/resource_pack.dart`,
  `lib/ui/resource_packs_ui.dart`, `lib/ui/look_picker.dart`, the look blocks in `assets/css/app.css`; Matt, 2026-11-27, of
  0.12.48 on his phone: "I see the runestone theme but I wanted it to use the duckscape look", then "I think we should
  add texture packs to all themes, but remove the phosphor entirely and remove the dark dial uptheme, also remove
  lamplight and mist and make them texture packs for the Ghost theme"). Four looks are offered: Uplink, Sharp, Dial-Up and
  Runestone. Settings › Appearance has **Textures** under every look: the look as it comes, then its packs, the one in use
  ticked. A pack is one of two kinds. Mist and Lamplight are Uplink's: each is still a value of `Look` with its own preset
  in the stylesheet (`Look.family`, `isPack`, `packs`), so everything that goes by the look in use draws them exactly as
  it did; they are only chosen under Uplink, whose tile is ringed and drawn in the pack. A look keeps the pack it was
  last in (`look_pack_<look>`), so Uplink is still in Lamplight after a while in Sharp. Runestone's are resource packs'
  pictures, and it has a usual one, Duckscape (`ResourcePacks.usual`): the pack chosen until another is, or plain stone,
  and fetched by itself the first time Runestone is the look, as the app starts in it or as it is chosen, and never
  before. Its row says Fetching while it is on its way and Try again where it couldn't be fetched, and the look is flat
  stone until it is here. Plain stone is kept as a choice (`resource_pack` empty), and nothing is fetched behind it.
  Sharp and Dial-Up have no pack yet, and say so. Phosphor is gone (its rules, and `Look.retired`: a device kept in it
  opens in Uplink with the bubbles it had before), and so is Dial-Up's dark half, After Hours: Dial-Up is always light.
  Tests: themes_test (looks and their packs), look_packs_test (the picker, and Textures under each look),
  resource_pack_test (the usual pack against a stand-in hub: fetched once, not before Runestone is the look, failing
  quietly, plain stone kept). Run for real on the emulator: Runestone chosen, and the app started in it with no pack on
  the device, each fetched Duckscape from the hub (539 KB) and drew with it. Not tried on the Mac app or an iPhone, and
  the section's new words are in English only.
- **Look: Runestone, and resource packs** (0.12.48; `lib/looks.dart`, `lib/packs/`, `lib/ui/resource_packs_ui.dart`,
  `lib/art/pixel_emoji.dart`, `lib/art/pixel_icons.g.dart`, Runestone's block in `assets/css/app.css`; Matt, 2026-11-27: "make a
  theme in Ghost that fits this with the runescape font and everything", of the Dark Vanilla resource pack for an old
  adventure game's interface, then "let's try the duckscape theme instead and bring in the pixelated looks"). A dark look
  drawn by Dial-Up's chrome (`lib/ui/dialup/`): stone windows, the game's lettering colours (yellow words, orange
  headings, white on what is pressed, each over a hard black shadow, through the kit's new `--glacier-text-shadow`), and
  chats and every text field on parchment (`.parchment`: dark inks, what you say in blue and what is said to you in dark
  red, six dark inks for a room). Its face is Runestone, the game's own letters as RuneStar/fonts traced them (CC0;
  `tool/runestone_font.py`, `assets/fonts/CC0-Runestone.txt`), with the curly quotes, "…" and "›" the app writes added.
  Every icon is in square pixels: Pixelarticons (MIT, `lib/art/PIXELARTICONS_LICENSE`) where it has the icon and the app's
  own redrawn in pixels where not (`tool/pixel_icons.py`, `tool/pixel-map.json`); emoji that are read (messages,
  reactions, the list's last line, buttons) are drawn sixteen pixels to the em. **Resource packs**: the look draws its
  buttons, windows, wells, headings, close button, parchment and the round frames of profile pictures from a pack of
  the game's players' own hub (github.com/melkypie/resource-packs), nine-patched with hard pixels. A pack is its
  artist's work and is never in the app or its source: Settings › Appearance › Textures lists the hub and fetches the
  one chosen to the device, at the commit the hub lists, kept as its archive and read as pictures only (not in a
  browser). With none, the look is flat stone. The look's flat colours are read off the pack's pictures and laid over the
  stylesheet (`ResourcePack.css`). Also for both bevelled looks: the rail of circles is drawn there now (it laid
  nothing out under Dial-Up), each ring and each circle a square push button; the list beside a pane has no border of
  its own under Runestone, so two panels' headings line up; the wide action button of the account pages and a reply to
  choose are push buttons. Tests: resource_pack_test (a pack made in the test and a stand-in hub on this machine),
  pixel_emoji_test, themes_test (Runestone's contrast on stone and on parchment, and every screen in it;
  `THEME_NAV=rail THEME_PACK=<a pack's archive> THEME_SHOTS=1` draws them with a pack). Looked at in the tests' pictures
  with Duckscape, Dark Vanilla and no pack; not tried on a phone, and fetching from the real hub was not run.
- **Looks: Dial-Up, Mist, Lamplight, Sharp and Phosphor** (0.8.4; `lib/looks.dart`, `lib/ui/look_picker.dart`,
  `lib/ui/dialup/`, `lib/ui/message_line.dart`, the look blocks at the end of `assets/css/app.css`; Matt, 2026-11-16: "spend
  some time making a few themes for ghost, base one of them heavily on the old AOL chatrooms"). As it was then: since
  "Looks and their packs", above, Phosphor and Dial-Up's dark half are gone and Mist and Lamplight are Uplink's packs.
  Settings › Appearance has
  a Look picker above Theme. Uplink is the app as it was. Mist is a pale aqua page with deep teal ink (light only),
  Lamplight a warm amber dark for late reading, Sharp high contrast in either brightness (its dark half true black), and
  Phosphor a green-screen terminal in JetBrains Mono with square corners. Dial-Up is a late-90s online chat room: silver
  bevelled windows, navy title bars (purple in its dark half, After Hours, after the era's high-contrast black scheme),
  Arimo (Arial's measures, OFL, bundled), each message a line of "Name: words" with your own in red and each other person
  in a colour of their own, Host lines ("*** You are in ... ***", who entered and left a space), People Here in a space,
  a "Send" button and a taskbar of buttons along the foot. No other company's name, marks or sounds are used. Each look
  brings its own bubble colour (the Theme swatch, `--app-bubble-mine`) and going back to Uplink puts back the colour you had;
  Ghost Keyboard is told the nearest of its colours. Red, indigo and the other fixed colours across the app became tokens
  (`lib/kit/semantic_colors.dart`) with their old values, so a look can change them. Tests: themes_test (tokens resolve
  and pass 4.5:1 in every look; `THEME_SHOTS=1` renders each look's screens to build/themes). The whole suite was not run
  at the end (Matt: "skip running the test suites for now"), and the six Appearance goldens in test/shots predate the
  Look section.
- **Telegram on a computer, approved by the phone** (0.7.46; `lib/inbox/telegram.dart`,
  `lib/ui/inbox_ui.dart`, the desk link's `telegram` request; Matt, 2026-11-16: "It seems i have to setup signal and
  telegram on each device is it possible to proxy through thr phone", then "Build the Telegram phone sign-in approval").
  On a computer paired with a phone that is signed in to Telegram, Telegram's sign-in starts with "Sign in with your
  phone": the computer asks TDLib for a login link (requestQrCodeAuthentication, the same link Telegram's QR code
  holds), sends it over the sealed desk link, and the phone approves it with confirmQrCodeAuthentication. The computer
  gets a Telegram session of its own, so no number and no code; it is listed in Telegram's Devices like any other. The
  phone approves only a `tg://login?token=` link and only when it is signed in; anything else is refused before
  Telegram is asked. A phone without this (older than 0.7.46) answers "Update Uplink on your phone"; the
  number sign-in stays beneath. Signal is not proxied yet. Tests: inbox_telegram_test, DeskSessionTest.
- **Telegram's and Signal's contacts in Contacts, and which way to write** (0.7.42, not released; `lib/inbox/people.dart`,
  `lib/ui/contacts.dart`; Matt, 2026-11-16: "Show telegram and signal contacts when linked with icons to show which
  each is and filters, where contacts can be messages on multiple platforms as which you like to use when stating a
  conversation"). Once linked, Telegram's contacts (TDLib's getContacts, kept in step by updateUser, their photos
  brought down) and Signal's (its contact sync, without the person themself) are in Contacts with the phone's. One row
  is one person: matched by number (its last ten digits), or, where one side has none, by the same full name of two
  words or more that names nobody else; two different numbers are two people. Each row ends with a mark for each way
  to write: text (or Uplink's tick for a friend), Telegram, Signal. Filters: All, Phone, and each linked network. A
  press on someone with one way goes straight there; with more, "Message … with" asks, each with its mark and who on
  that network (handle or number). A Telegram chat is made with createPrivateChat; a Signal one is the person's ACI
  and is in the list from its first message; either opens with the person's name and face (InboxChatScreen's
  fallback). A number known from Telegram or Signal can be texted too. Tests: inbox_people_test, inbox_screens_test
  (16-inbox-contacts), inbox_telegram_test, inbox_signal_test.
- **Set up RCS, and Uplink's notifications in place of Google Messages'** (0.7.29; `lib/ui/rcs_setup.dart`,
  GmBridge.kt; Matt, 2026-11-15: "add a button under messages settings to setup RCS if on an android phone and walk
  the user through how to enable the rcs sidecar"; "we should have a way to make the app work without needing to be
  the default sms app so it can work in tandem and I can turn off notifications from google messages or hide them and
  proxy everything through ghost"). Settings › Messages › Set up RCS walks through six steps, each ticked as Android
  says: Google Messages installed, made the default, RCS chats on in it, Uplink allowed texts, notification access,
  Google Messages' notifications set to Silent; then how to pair a computer (Settings › Google Messages there). When
  Google Messages becomes the default, Android takes Uplink's SMS permissions back and the walkthrough opens at its
  texts page, carrying on with the same steps (`rcs_setup`). Beside Google Messages, each of its message
  notifications is hidden as it comes and Uplink's own shown (Settings › Notifications, `gm_proxy`, on by default);
  replying from Uplink's goes back through Google Messages. Never hidden where Uplink may not post notifications.
  Google Messages' own must stay allowed (Silent): they are what Uplink reads. Checked on an emulator: Google
  Messages' notification gone, Uplink's shown, a reply from it sent through Google Messages.
- **Google Messages set up by Google account, in one place** (0.7.33; `lib/gm/google_signin.dart`,
  `lib/gm/google_signin_flow.dart`, sidecar `pair_google`; Matt, 2026-11-15: "it seems they removed the ability to do
  it with the QR code"; "Please make setting up google messages a onboarding flow that is all in one place. It should
  also needs to if possible prompt to open the link incognito"). Google has replaced Device pairing's QR scanner with
  Google-account pairing where Google Messages is signed in to an account (mautrix-gmessages: "it appears Google has
  killed it"). Settings › Google Messages on a computer, and Settings › Messages › Google Messages connection on the
  phone, walk through it: sign in at Google's account chooser (coming back to messages.google.com/web/config) in a
  private window (the computer opens one: Firefox first, since Chrome may bind the sign-in to itself, then Chrome,
  Edge, Brave, Vivaldi; Safari has no switch, so the link is copied), copy the "config" request as cURL from the
  developer tools, paste it, tap the emoji Uplink shows when Google Messages on the phone asks. The helper keeps the
  cookies in its session (saved every few minutes, as Google changes them); the private window is closed after, not
  signed out. The QR way stays as Pair with a QR code instead. The phone's browser has no developer tools, so on the
  phone steps 1 and 2 are done on a computer. Checked: Google refuses fake cookies with a readable reason, a paste
  missing cookies is caught first; real pairing not yet.
- **A guide to the Google Messages helper on a Mac or PC** (0.7.30; `lib/ui/gm_guide_screen.dart`; Matt,
  2026-11-15: "Tell me how to setup the sidecar on mac and PC in a guide found in settings I'll habe it run on my PC
  always"). Settings › Messages › On a Mac or PC on the phone, and Settings › Google Messages on a computer: get the
  app, pair it with the phone, pair Google Messages by its QR code, keep it running (the desktop apps quit when their
  window closes and don't start at login yet, so: minimise; Windows' shell:startup shortcut; the Mac's Login Items;
  stay awake), and the one-session rule with the phone's own connection.
- **Google Messages' web connection on the phone** (0.7.30; `GmWeb.kt`, `lib/ui/gm_web_screen.dart`,
  `site/pair`; Matt, 2026-11-15: "Can you build the on phone google messages connection too?"). The sidecar built for
  Android (`tool/build-gmsidecar.sh android`, libgmsidecar.so, run from the app's native library folder) runs in the
  app's process, started by the notification listener (which Android keeps) and the app. What it hears goes into the
  bridge's database, so the list, conversations, Uplink's notifications, replies and a paired computer all have it:
  RCS and texts, pictures (brought down on demand), reactions, and delivered and read marks (blue double check).
  Sending, pictures included, and marking read go through it when connected; else the notification bridge as before.
  Google Messages' notifications can then be off altogether. Pairing: the phone cannot scan its own screen, so
  Settings › Messages › Google Messages connection shares a link (gogho.st/pair/#secret) to open on another screen;
  the secret gives a room on the relay and its key, the phone says each new QR code there sealed, and the page draws
  it (the relay sees ciphertext; the secret never leaves the link). Google Messages keeps one web session: the phone's
  takes it back (`--takeover`) and a computer whose sidecar is pushed off shows the phone's conversations through
  the phone. Also: pictures sent beside Google Messages without the connection go to its compose with the words.
  Checked on the arm64 emulator: the helper runs, gets a pairing code from Google, and the page (served locally,
  against the live relay) drew it. Not checked: pairing with a real phone, and everything after it.
- **Which of Google Messages' notifications still make a sound** (0.7.29; GmBridge.kt `noteChannel`; Matt,
  2026-11-15: "investigate silencing google messages notifications so we only see thr ones coming through ghost
  instead"; "Let's do our best given these options and push out an update"). Android lets no ordinary app change
  another's notification settings, and a notification is heard before Uplink can take it away, so the person silences
  Google Messages. Uplink records the channel each of its message notifications comes on (a listener is shown each
  one's settings): its "Incoming messages", and any conversation given a sound of its own, which overrides that one.
  The RCS guide's last step lists the ones still loud, each with a button to its own page in Android's settings, and
  ticks itself once all are quiet (as of each channel's last message). Your read receipts already go out through
  Google Messages' Mark as read; their delivered and read marks are not in notifications, so they need the on-phone
  Google Messages connection (not built).
- **Google Messages on the computer** (0.7.29, the sidecar in the Mac and Windows apps; `lib/desktop/gm_web.dart`, `sidecar/gmessages`; Matt,
  2026-11-15: "Yes, mautrix sidecar"). Settings › Google Messages on the Mac or Windows pairs the computer with Google
  Messages by a QR code, as messages.google.com is, and every conversation there joins the desktop's list: RCS and
  texts, history, pictures, reactions (shown under the words). A phone conversation with the same people is shown
  once, from Google Messages. Sending text and marking read go to Google Messages; pictures to its conversations are
  sent from the phone for now. It is done by a separate program, the sidecar (Go, built on mautrix-gmessages' libgm,
  AGPL-3.0, `tool/build-gmsidecar.sh`), which the app starts and talks to over its standard input and output; nothing
  of it is linked into Uplink. Its session is kept in the app's folder. Releases carry it only once its source is
  public: `sidecar/gmessages/SOURCE_URL` names where, and release-mac.mjs and messaging-windows.yml leave it out until
  that file exists. Checked: the sidecar asks Google for a pairing code; pairing with a phone not yet.
- **Or works beside Google Messages, keeping RCS** (0.7.25; `GmBridge.kt`; Matt, 2026-11-15: "I'd like
  to see if there is a way we can proxy messages from google messages to ghost so we can support RCS and other
  features ... I'd like to have a way that people can reliably get text in and out of ghost without needing to switch
  the default messaging app"; then "Both, notifications first"). Google Messages stays the default. Uplink reads texts
  from Android's database (READ_SMS, asked for) and RCS chats from Google Messages' notifications (notification
  access; only Google Messages' are read), into `gm_bridge.db`, joined to Android's thread where the people are known.
  A message Android already has (the same words within three minutes) is shown once. Replies go through the
  notification's own Reply (RCS where the chat is RCS), else as SMS to one number, else Google Messages opens with the
  words filled in. Not seen: chats muted in Google Messages or open there when a message comes, RCS from before, RCS
  pictures; Android 15's hidden one-time codes are skipped (they are texts, read in full from Android). Delete and
  mark read touch only Uplink's copy and Google Messages' Mark as read. Checked on an emulator with SMS; a real RCS
  chat not yet. Next: the Messages for Web protocol on the computers, for history, pictures and reactions.
- **Conversations**: newest first, with contact names and photos, unread dots, a "Not sent" mark, search over
  names, numbers and the last message, long press to mark as read, archive (this app's own list) or delete.
- **A conversation**: bubbles grouped by sender and minute, day headings, sender names and faces in a group,
  Sending / Sent / Delivered / Not sent (tap to try again), pictures inline (tap to zoom), links underlined, long press
  to copy, delete or send again, a call button, and a counter once a text runs to more than one SMS.
- **Sending**: one person gets an SMS (split into parts when it's long). Several people, or a picture (up to five,
  scaled to the carrier's MMS size limit), get an MMS.
- **Receiving**: SMS, and MMS downloaded through Android's MMS service, decoded and stored, including group MMS. Group
  MMS leaves this phone's own number out of the list of people; when Android won't say what the number is, it can be
  typed in Settings.
- **Notifications**: one per conversation with its unread messages (MessagingStyle), with Reply and Mark as read.
- **Other apps**: `sms:` / `smsto:` / `mms:` links, shared text, and "respond via message" from the call screen.
- **Reactions** (0.2.0): texts like `❤️ to "See you at 7"` (Google Messages) or `Loved “See you at 7”` (iPhone)
  are folded onto the message they name, as a chip on its corner, instead of a bubble of their own: hearts, likes,
  laughs, `Reacted 🎉 to …`, reactions to a picture (`Loved an image`), and `Removed … from …` taking one off. A press
  on the chip lists who reacted with what. A quote cut short with "…" still finds its message; a reaction that names
  no message in the conversation stays an ordinary bubble. It works on old messages too, because it is read as the
  conversation is drawn (`lib/reactions.dart`, tested by `test/reactions_test.dart`).
- **Editing** (0.2.0): long press one of your messages, Edit. SMS can't change a text on the other person's phone, so
  saving asks whether to send the change as a follow-up text ("Correction: …") or change it on this phone only. The
  bubble says "Edited" (or "Edited · correction sent", with the correction's own bubble folded away), and a press on
  that shows what it first said. Editing a message that failed sends it again with the new words. The first text is
  kept in the app's own record (`Store.editMessage`, `lib/edits.dart`).
- **Sending reactions** (0.3.0): long press a message and pick ❤️ 👍 👎 😂 ‼️ ❓ or more. It goes as the iPhone's
  wording ("Loved “…”"), which Google Messages and Samsung Messages turn back into a reaction on the other phone and
  this app folds too. A press on one that is already yours takes it off ("Removed a heart from “…”").
- **Effects** (0.3.0; [docs/effects.md](effects.md)): twenty screen effects set off by a phrase or by a message of
  key emoji: the iPhone's eight (echo, spotlight, balloons, confetti, love, lasers, fireworks, celebration), the ones
  Google Messages plays on a phrase (snow, kisses, wow, thank you, good night, good morning, get well soon, bye bye,
  hungry, sorry, party time), and ghosts for "Boo". An iPhone's "(sent with Lasers)" is read, played and not shown,
  and so are its bubble effects (slam, loud, gentle, invisible ink). One to three emoji alone are drawn large. Since
  0.6.0 each effect moves pictures drawn for it (below). Settings › Effects turns
  them off, and lists every one with what sets it off; a tap plays it there.
- **Emoji sets** (0.3.0; `lib/emoji_sets.dart`, `assets/emoji/LICENSES.md`): the phone's own, Noto, Twemoji, OpenMoji
  or Noto's outline face, chosen in Settings and drawn everywhere in the app. `test/emoji_sets_test.dart` holds each
  set to drawing joined emoji (families, skin tones, flags, keycaps) as one glyph.
- **Ticks** (0.3.0): one for sent, two for delivered, two in colour for read, on every message of yours. Delivered is
  the carrier's delivery report (SMS and MMS). Read is an MMS read report, which is asked for on picture and group
  messages (Settings › Receipts) and which only some phones send; a plain text has no way to say it was read.
- **Pin, mute, block** (0.3.0): from a conversation's long press. Pinned ones stay on top; muted ones arrive without a
  notification; a blocked number goes on Android's own blocked list, which stops its texts and calls for every app.
- **Drafts** (0.3.0): what is typed and not sent is kept for its conversation and shown in the list.
- **Sign-in codes** (0.3.0): a notification for a text with a code in it has a "Copy 482913" button.
- **Updates** (0.3.0): the app looks at https://ghost-sms.com/apk.json as it opens (at most twice a day), downloads a
  newer release, checks its size, hash and signing certificate, and installs it (`Updater.kt`, Ghost Keyboard's).
  Settings › Updates has the switch, "Check for updates" and "Update now". It is the only connection the app opens.
- **Your bubbles** (0.3.1): Ghost Keyboard's primary by default (its accent: #51FCFB under dark teal on the dark
  page, #008B8A under white on the light), or the page's ink, or (0.4.0) the accent Android takes from the phone's
  wallpaper, in Settings › Appearance.
- **Encryption** (0.4.0; Matt, 2026-11-13: "enable an option for an additional level of E2E encryption by allowing
  users to exchange keys somehow and then encrypt all messages so only others with the app can read them"). With one
  person who also has Uplink, texts go sealed so only the two phones can read them. It is turned on from a
  conversation's header (tap the name, Encryption): that sends one text with this phone's key, and the other person
  gets a bar over their composer, "Maya wants to encrypt this conversation", with Turn on, which sends theirs back.
  From then the header says "Encrypted" with a lock, the composer "Encrypted message", each sealed message has a small
  lock by its time, the conversation has one after its name in the list, and the two key texts are drawn as lines
  ("You sent your encryption key"), not bubbles. The header's Encryption also shows the safety number, thirty digits
  that are the same on both phones when nobody swapped a key on the way, with "They match: mark as verified". A
  DIFFERENT key from someone already exchanged with turns encryption off until it is looked at and accepted. A sealed
  text whose key is gone (a reinstall, a new key) says "Encrypted message that can't be opened on this phone".
  What it is and is not, as Settings › Encryption says it: one person at a time (groups and pictures are MMS and go
  as they always have, and attaching a picture says so); the keys travel by SMS, so the safety number is what rules
  out a swapped key; no forward secrecy (no ratchet: it is not Signal's protocol); a sealed text is longer, so the
  composer counts the texts it will cost; to any other app a sealed text is a line of letters. The cryptography is
  `E2eCrypto.kt` (P-256, ECDH, HKDF-SHA256, AES-256-GCM; `E2eCryptoTest`), what the phone keeps is `E2e.kt`, and the
  screens are `lib/ui/thread.dart` and `lib/ui/encryption.dart`.
- **Chat backgrounds** (0.4.0; Matt, 2026-11-13: "allow changing the backgrounds for chats, there should be a standard
  way to have the backgrounds sync between apps as my google background syncs with samsung messenger"). One for every
  chat (Settings › Chat background) and one a conversation may have of its own (its header › Chat background): none,
  eight washes made for the app (pale in light, deep in dark), a colour (twelve offered, or mixed), a picture from
  the phone (a copy the app keeps, drawn under a veil, with the small words on pills), or **Match my wallpaper**.
  There is no standard by which texting apps share a background: Google Messages keeps its own on the phone that set
  it, for RCS chats only, where no other app can read it. What every app can share is the palette Android takes from
  the wallpaper (Material You, Android 12 on), and that is what Match my wallpaper wears, so it follows the phone as
  Google's and Samsung's apps do (`lib/backgrounds.dart`, `MainActivity.systemPalette`).
- **Synced backgrounds** (0.5.0; Matt, 2026-11-13: "I want the background to sync for everyone in a chat if they're
  all using ghost messaging"). A conversation's own background (its header › Chat background) has a switch, "Sync
  with Maya" ("with everyone here" in a group). On, what the conversation wears is sent to its people as the page is
  left, once, and their Uplink wears it too; what they choose comes back the same way, so the newest choice
  is everyone's. There is no server, so it goes as a text in the conversation (`BackgroundWire.kt`:
  `ghost:bg1:preset:dusk`, `color:#RRGGBB`, `none`, a wash's four colours for Match my wallpaper, since the other
  phone's wallpaper is its own, or `image` with the picture in the same message as an MMS, at the size the carrier
  allows). Both phones draw that text as a line, "Maya changed the chat background", not a bubble. It is sealed with
  the rest where encryption is on. The switch is on by itself only where everyone is known to have the app, which is
  once a text only the app writes has come from them (a key, a sealed text, a background: `Backgrounds.kt`); to
  anyone else it would arrive as a line of letters, and the page says so before it is switched on by hand. Settings ›
  Chat background › Wear backgrounds shared with you turns the receiving off. Every chat's background (the one in
  Settings) is this phone's alone.
- **Sign-in codes for Ghost Keyboard** (0.5.0; Matt, 2026-11-13: "The messaging app should also work with ghost kbd to
  proxy verification codes"). Ghost Keyboard shows a one-time code above its keys to tap in, but reading texts itself
  needs a permission Android 15 refuses apps from outside a store, and Android 17 holds code texts back from every
  app but the default SMS app. This app is the default SMS app, so it answers the keyboard instead (`Codes.kt`):
  a content provider, `content://com.infamousvague.ghostmessaging.codes/latest`, which looks through the texts of
  the last ten minutes with the finder the notification's Copy button uses and answers with the codes and when they
  arrived: three at most, never the words or who sent them, and nothing is kept for it. It answers Ghost Keyboard
  alone, known by its package and the SHA-256 of its release certificate; the keyboard pins this app's in turn (its
  `GhostMessagingCodes.kt`, docs/ghost-messaging-codes.md there). When a text with a code arrives, a keyboard that is
  watching is told to ask. Settings › Ghost Keyboard has the switch (on to start) and says whether the keyboard is on
  the phone. Needs Ghost Keyboard 0.18.0 or later.
- **Coming from Google Messages or Samsung Messages** (0.6.0; `Arriving.kt`; Matt, 2026-11-13, of a friend whose
  chats "didn't load into ghost messaging" and whose texts stopped arriving: "can you detect this somehow and then
  instruct the user how to fix it?"). Two things catch people, and neither is this app's doing. RCS chats are kept
  inside the app that made them, where Android lets no other app read them: they do not appear here, and they are not
  deleted (the app deletes only on Delete conversation, Delete message, and resending a failed one). And while RCS
  chats are on, the number stays registered for RCS, so people whose phones use RCS go on sending chats that never
  arrive as texts. Android tells no app whether RCS is on for a number, so that is never claimed; what is seen is the
  default SMS app before this one, whether it is still on the phone, how many texts Android's store holds and how few
  are recent, and whether this copy came from a file. The setup screen names the app being left and has "Open Google
  Messages settings" (its General settings, RCS chats first) before the switch; after it, a dismissible notice heads
  the list ("Texts from some people not arriving?") and Settings › Android has the two ways out: Google's page that
  turns RCS off with a code it texts (`messages.google.com/disable-chat`; the text arrives here), or handing the role
  back for a moment. The list's empty state says where RCS chats are, and Settings › Android says what Android's store
  holds, so "nothing was read" can be told from "there was little to read". **This app does SMS and MMS only: no app
  but Google's can do RCS on Android.**
- **Allow restricted settings** (0.6.0; Matt: "until we get on the play store add a link to open the app in settings
  to allow elevated access"). Android 13 and later may refuse a copy installed from a file the SMS role or a
  permission. Where the switch is refused, the setup screen leads to Android's page for the app (⋮ › Allow restricted
  settings), and Settings › Android has the same link while the copy is one from a file.
- **Loading, and reading that fails** (0.6.0; Matt: "Show a loading indicator when messages are syncing"). The list
  says "Loading your conversations…" under an arc the first time, shows a thin bar under the search when a later
  read takes a moment, and a conversation says "Loading messages…". A read that fails is said, with Try again, never
  shown as an empty list; a store that will not list its conversations is read from the texts themselves
  (`Store.conversationsFromTexts`), and a conversation whose count the store says is nothing is checked before it is
  left out.
- **Several conversations at once** (0.6.0; Matt: "allow selecting multiple convos to delete them"). A conversation's
  long press has Select; then a tap adds or takes away, the bar counts them, and they are deleted (asked first, with
  how many) or archived together. Android's Back leaves choosing first.
- **Finding each other, and the encryption banner** (0.6.0; `GhostMark.kt`; Matt: "detect if both users are using
  ghost messaging", "it should show a banner that can be dismissed asking the user to enable encryption for better
  security"). With no server to ask, a copy of the app says it is there in its texts: three invisible characters at
  the end of one, at most once a day to a person, only while nothing has been exchanged with them, only where the
  text stays the same number of SMS, and never on a reaction or one of the app's own `ghost:` texts. Every other app
  draws them as nothing; another copy remembers the person has the app. Their conversation then shows a banner over
  the composer, "Maya has Uplink too. Encrypt this conversation for better security?", with Turn on (which
  sends this phone's key; the other person's bar then has Turn on too) and a cross that puts it away for that
  conversation. Nothing is sent because of the hello. Settings › Encryption › Find people who have Uplink
  turns the hello off.
- **Bubble colours** (0.6.0; Matt: "a suite of colors to pick for the chat bubbles including white and gray"):
  Uplink, Ink, Wallpaper, White, Silver, Gray, Graphite, Blue, Indigo, Purple, Pink, Red, Orange, Yellow, Green and
  Mint, the words on each black or white, whichever reads, and a line round a bubble the page would swallow.
  Settings › Appearance for every conversation, and a conversation's own in its settings.
- **Each conversation's own settings** (0.6.0; `lib/ui/chat_settings.dart`; Matt: "each chat should get it's own
  settings cog"): a cog at the conversation's top (and a tap on the name) opens its people, its background, your
  bubbles in it, its encryption, and mute, pin and archive.
- **The keyboard comes back** (0.6.0; Matt: "tabbing in and out of the app again makes it so the keyboard dissapears
  but the input stays selected so there is no way to re open the keyboard"). A tap on a field that already has the
  cursor where it was tapped changes nothing, so Flutter asked for no keyboard. Any tap on the message field asks
  for it now, and coming back to the app with the cursor in the field brings the keys back.
- **The icon** (0.6.0; Matt: "update the icon to use the one from the desktop"): the white ghost that is a speech
  bubble, on black (`art/app-icon.png`; `python3 tool/app_icon.py` makes the adaptive icon, the themed layer, the
  notification's icon, the setup screen's mark and the site's icons from it).
- **Speed** (0.6.0; Matt: "work on improving speed and performance"). Who a number is is kept until Android says the
  contacts changed, where it was asked again for every conversation on every text that came or went; Android's
  blocked list is read once for the whole list; a conversation's picture messages are read in one question, and who
  sent each is remembered; pictures are read apart from everything else and only the last forty are kept in memory;
  typing no longer redraws the messages; the app's start asks for its stylesheets, choices and wallpaper colours
  together. On an emulator with 161 conversations the list's first read took 697 ms and each one after 7 to 9 ms
  (before, every read was a first read). `adb shell setprop log.tag.GhostPerf VERBOSE` before the app starts writes
  each call's time and the frames' to Android's log.
- **The effects' characters move** (0.6.2; Matt, 2026-11-13: "i'm going to include 6 frame animations for each
  asset in a sprite sheet", then "Push an update and release after you've sliced all the animated pictures sprites
  and the sticker pack from the desktop"). Seventy-eight of the eighty characters came drawn six times each, three
  across and two down, in files named for the effect and the character's place on its sheet
  (`bye_r1c2 · wave right hand.png`). `python3 tool/effect_anims.py ~/Desktop/Animated` finds each drawing by its
  shape (`effect_sprites.cut_grid`) and lays the six side by side as they stood in their places, so what moves
  between drawings moves and what keeps still keeps still: `assets/effects/<effect>-a<N>.webp`, 5.5 MB in all, with
  a picture of each strip in `build/effect-anims/`. The app plays a character's strip at eight drawings a second
  where it has one, each character starting on a drawing of its own, and shows the still where it has none
  (`EffectSprite`; balloons' first and confetti's second character are not drawn yet). The drawings themselves, a
  quarter of a gigabyte, are not in the repository: they are in the folder Matt keeps them in.
- **Mischief, a fifth sticker pack** (0.6.2): the dark-cute one, drawn for itself: our ghost with little horns and a
  heart-tipped tail in black, purple and hot pink. Its sheet of sixteen (`art/stickers/mischief.webp`) is cut by the
  same tool as the other packs (`python3 tool/sticker_packs.py mischief="<the sheet>"`). With five packs the
  sheet's tabs slide, and the pack it opens on is brought into view.
- **Swiping a conversation** (0.7.3; Matt, 2026-11-14: "add swiping to archive, further drag to delete, drag the
  other direction to pin, add haptic detents for each"). A row of the list dragged to the left uncovers Archive,
  dragged further Delete, and dragged to the right Pin (`lib/ui/swipe_actions.dart`). Each is a detent: the phone
  ticks as the row passes into Archive or Pin, knocks harder into Delete, and ticks lightly on the way back out, so
  the hand knows what letting go will do. Letting go does it and the row slides back; deleting still asks first.
  Archive, pin and delete change the list at once, before Android has answered.
- **Deleting that says when it has not** (0.7.3; Matt: "deleting messages isn't working"). On an emulator a text, a
  picture message and a whole conversation all delete, so what he met could not be made to happen here. What was
  wrong either way: a delete Android refused left no word (the screen said "deleted"), and a deleted conversation
  stayed in the list until every conversation had been read again. `Store.deleteMessage` and `deleteThread` now ask
  a second way where the first deletes nothing, check that the thing is gone, and tell the screen if it is not
  (with a line in Settings › Developer); the row or message goes from the screen at once and comes back with the
  reason if Android would not delete it.
- **The update banner, redone** (0.7.3; Matt: "Redo the update banner to show over the content but not over the
  header, make it have an x button and be more colorful"). A card in indigo, violet and pink that hangs under the
  page's header (`HeaderEnd` marks where each page's header ends; on the list that is under the search field) and
  over its content, with Update now and a cross that is always there. It was a bar across the very top that pushed
  every page down.
- **White bubbles** (0.7.3; Matt: "change the default chat bubble to be white"): your own bubbles are white where
  no colour has been chosen, with the line a white bubble needs on the light page. Anyone who chose a colour keeps
  it; Settings › Appearance has the others, the old teal ("Uplink") among them.
- **The logo where there is nothing** (0.7.2; Matt, 2026-11-14: "I also want the ghost image used when there are no
  messages to use the logo"). The empty list, an empty archive and a search that finds nothing show the app's own
  mark, the white ghost on black as it is on the home screen (`GhostLogo` in `lib/ui/common.dart`), where an
  outline of a ghost stood.
- **Reactions, plainer** (0.7.2; Matt, 2026-11-14: "The reactions should show up under the context menu not a second
  row under emoji, don't shwo the border on the emoji reaction just show the emoji's with no background pinned under
  it a bit larger"). Holding a message shows the reactions, then what can be done with the message, then the screen
  effects in their row under that menu, where the effects sat between the two (`lib/ui/message_popover.dart`). A
  message's reactions are the emoji alone, a little larger, pinned under the bubble: no chip, line or shadow round
  them, and a count only where there are more reactions than emoji shown (`_ReactionChip`).
- **Updates while the app is in front** (0.7.2; Matt, 2026-11-14: "it should auto check for updates when the app is
  in focus"). The app looks at ghost-sms.com each time it comes forward and every ten minutes while it stays there
  (`Updater.focusCheck`, from `MainActivity.onResume`; no oftener than once a minute), where it looked as it opened
  at most twice a day and as a page opened. What it finds is on the banner over every page; with automatic updates
  on it downloads, and installs by itself where Android allows that without asking.
- **Mischief moves** (0.7.1; Matt, 2026-11-14: "Update the sticker pack to use the animated sprites from the
  desktop"). `~/Desktop/AnimatedStickers` held each of the pack's sixteen stickers drawn six times;
  `python3 tool/sticker_packs.py mischief=~/Desktop/AnimatedStickers` cuts each into its drawings, lays them in one
  frame as they stood, gives each the white edge and writes an animated PNG (`assets/stickers/mischief/07.png`,
  320 pixels, 130 ms a drawing, 157 to 217 KB): one file that is the sticker in the app and what is sent. An
  animated PNG moves on an iPhone and in this app and is an ordinary still picture, its first drawing, to an app
  that does not know the kind, with its clear edge kept either way; a GIF would move everywhere but has no soft edge
  and few colours. The colours are chosen for it (`few_colours`: median cut and dithering for what is solid, a few
  greys at a few strengths for the soft edge), since the first attempt banded. `Sender.sendSticker` sends one that
  moves as it is (`Stickers.moves` looks for the animation's mark). The other four packs are stills as before; the
  drawings themselves (44 MB) are not in the repository.
- **Picture messages that keep trying** (0.7.0; Matt, 2026-11-14: "let's focus on reliability of sending pictures
  and whatnot"). A picture message that fails for want of a connection, or because the carrier's server is in
  trouble, is sent again by the app itself after twenty seconds and again after ninety (`MmsWhy.worthAnotherTry`,
  an alarm to `MmsResultReceiver.RETRY`), standing as Sending meanwhile; the person is told only if the third try
  fails too. Not where they have to do something first (mobile data off) or the carrier said no to the message. A
  picture message that was fetched and could not be read used to be gone, since a carrier lets go of a message once
  it is fetched: its bytes are now kept (`files/mms-kept/`) and read again each time the app comes forward, which
  is after every update, when the reading may have been mended; the Developer log says why it could not be read and
  how it begins. And a message left on Sending for a quarter of an hour (the phone switched off, the app stopped
  before Android answered) is marked not sent, so it can be tried again (`Store.failStale`). Tried against the
  stand-in carrier: with its server refusing the first four attempts, the first try failed, the app tried again
  unasked and the sticker went; a message it could not read was put by and logged.
- **Picture messages that say why** (0.6.2; Matt, 2026-11-13: "It seems like picture sending is also not working at
  all almost like MMS isn't working"). Picture messages had never run anywhere, so they were run: on an emulator
  with a stand-in for a carrier ([tool/mms/](../tool/mms/README.md)) a sticker and a 4000×3000 photo went out, both
  read back whole by Android's own parser (`PduParser`), and a picture message announced to the phone was fetched,
  stored and shown. So what stops one on a real phone is the phone's or the carrier's, and the app now says which.
  A picture message that fails says why under it ("Not sent: mobile data is off. Picture messages need it, even on
  Wi-Fi."; `MmsWhy.kt`, from Android's result code and the carrier's HTTP answer). A carrier that takes a message and
  refuses it in its answer (X-Mms-Response-Status), which Android reports as sent and the app used to show as Sent,
  is shown as not sent with the carrier's own words. The message field says what would stop one before it is tried
  (mobile data off, the carrier's settings disallowing it, no SIM). A picture message announced and not fetched used
  to be lost; now it waits and is asked for again each time the app comes forward, for five days (`MmsDiag.kt`).
  Settings › Android › Picture messages shows all of it, how the last one sent and the last one received went, and
  copies a report with no messages, names or numbers in it.
- **Photographs** (0.6.2; Matt: "Stickers seem to work fine its specifically media messages like pictures"). What a
  photograph goes through and a sticker does not was read again and tried, and four things were wrong. Trying a
  failed picture message again sent its words alone as a text and deleted it, so the picture was gone: it now goes
  again with its own pictures, read back from Android's store (`Sender.resendMms`). On a message that was a picture
  and no words, "Tap to try again" did nothing, because the picture's own tap (open it) won and the red line took
  none: both send it again now. A picture that could not be read was left out without a word and the message went
  with nothing in it: now nothing goes, and the screen says why, with the pictures put back in the field. And the
  JPEG made from a phone's HDR photograph carried a second picture inside it (a gain map), which a carrier's server
  is not known to take: a plain eight-bit JPEG is made (`shrink`). A message is never made larger than 1 MB whatever
  the carrier's settings say, and one the carrier refused goes again with its pictures under 300 KB in all.
- **Settings › Developer** (0.6.2; Matt: "Maybe it would be good to include a developer setting with copying errors
  and reporting"): the app's own log (`DevLog.kt`, the last 300 lines, kept in the app's files): every call that
  failed, every error on the screens' side, and each picture message as it went (what the picture was, what it was
  made into, the carrier's limit, Android's result, the carrier's HTTP answer and status). Copy the report, Share
  the report (Android's share sheet: an email, a note), Clear the log. No message's words go in it and what looks
  like a phone number is struck out.
- **A phone with a great many messages** (0.6.1; Matt, 2026-11-13: "Users with a ton of messages stored on their
  phone are taking forever to load, see if we can load by most recent first so that things are faster"). Measured on
  an emulator filled by `python3 tool/seed_store.py emulator-5586` with 3,000 conversations, 126,000 texts and 19,600
  picture messages: 0.6.0 showed nothing for 21 seconds, read the whole list again for 5 seconds every time a text
  came or went, and held a conversation's messages behind that read. Now the list is read the newest first
  (`Store.conversationsPage`, `_load` in `lib/ui/conversations.dart`): the newest forty and the pinned ones at once,
  which is the screen, in about a tenth of a second, then the rest 250 at a time behind them (4.6 seconds for all
  3,000 the first time, under a tenth after), with "Loading older conversations…" at the list's foot. A text that
  comes or goes reads only the newest again (13 ms). What made it slow was a question to Android for each
  conversation where one does for all: every conversation's address (`readCanonical`), every contact's numbers
  (`knownNumbers`, found by `ContactKey` and then compared whole as before), and the summary of a conversation whose
  newest message is a picture, which is now read once and kept until the conversation changes (`latestSnippet`). The
  list is read on a thread of its own, so nothing waits behind it. A conversation opens on its newest 120 messages
  and reads 300 more each time the reader nears the oldest held; before, the newest 300 were all it could show.
  Settings and a conversation's own settings no longer read the whole list to learn one thing.
- **The effects' own pictures** (0.6.0; Matt: "the ghost messages assets are on the desktop, please wire them all and
  slice them up"). Each of the twenty effects has a sheet of about twelve sprites drawn for it
  ([docs/effect-sprites-prompt.md](effect-sprites-prompt.md)): four ghost characters and eight props.
  `python3 tool/effect_sprites.py <folder>` keeps the sheets in `art/effects/` (lossless, the background remover's
  halo cleared) and cuts each into its sprites by shape, not by a grid, into `assets/effects/<effect>-h1.webp…` (the
  characters) and `-p1.webp…` (the props), with a picture of every sheet's cuts in `build/effect-sprites/` to look
  over. The app moves them (`EffectSprites` and `_spritePlans` in `lib/effects.dart`): props many and small,
  characters few and large, rising, falling or bursting as the effect does. What only the app can draw stays under
  them: the fireworks' and lasers' light, the spotlight, Echo's copies of the message's words. An effect with no
  pictures is drawn as before. 240 sprites, 2.6 MB.
- **Reactions under the message, and effects as reactions** (released by 0.7.4; Matt: "I want the message reactions to
  pop up under the message like imessage does", "I'd like to be able to react with full screen effects by pressing
  and holding on a message as well"). A long press on a bubble dims the page round it and brings up, beside it, the
  reactions, then the twenty screen effects, then Copy, Edit and Delete (`lib/ui/message_popover.dart`). An effect
  chosen there goes as a reaction with the effect's own emoji (`Reacted 🎈 to “…”`), which every phone can read; this
  app hangs it on the message and plays the effect over the conversation, on both phones, once.
- **A picture that could not be downloaded** (released by 0.7.4; Matt: "the message app said that a photo could not be
  downloaded… when I tap it I'd like it to take me to the associated chat and show the failed image with a retry if
  needed"). A picture message is announced by the carrier first and fetched after. The announcement is now kept in
  the sender's conversation until the picture is here (`Store.insertMmsNotice`): "Downloading picture…" while it
  comes, and where it cannot be fetched, "This picture couldn't be downloaded" with Try again, which asks the
  carrier for it once more (`MmsPushReceiver.retry`). The notification opens that conversation. Before this the
  notification led nowhere and nothing was kept to try again from.
- **The update banner** (released by 0.7.4; Matt: "the app should auto check for updates on load of any page so it pops
  the banner"). Every page that opens asks for a look for a newer version, made no oftener than every five minutes,
  and while one is waiting a banner over every page says which, with Update now (`lib/ui/update_banner.dart`).
- **Voice messages** (released by 0.7.4; `Voice.kt`, `lib/ui/voice.dart`; Matt: "I also want to have the ability to send
  audio messages"). With nothing written, a microphone stands where Send would. Tap it and the composer becomes the
  recording: a clock, how loud it hears you, how long one may run, a bin to throw it away, Send. It goes as a
  picture message does, an MMS with one sound in it (AAC in an `.m4a`, about three kilobytes a second), so any phone
  can play it and it is not encrypted, which an encrypted conversation says before it goes. How long one may run is
  what the carrier lets a message weigh: about a minute and a half at 300 KB, about five minutes at 1 MB; the
  recorder stops itself there. One that comes or goes is drawn as a player: play and pause, how far through, how
  long. Android gives the default SMS app the microphone along with the role, so it is asked for only where that was
  taken back; it is open only while a recording is under way with the app in front, and leaving the app throws the
  recording away. One that did not go is sent again whole by 0.6.2's `Sender.resendMms`, as a picture is. On a Mac a
  voice message is named and not played.
- **Stickers** (0.6.0; Matt: "generate 4 sticker packs using our ghost mascot we've developed including a sanrio
  one"). Four packs of sixteen, made by `python3 tool/sticker_packs.py` from the ghost's poses on the effects' sheets,
  each with a sticker's white edge: **Uplink** (hello, boo, wow, sorry, coffee, asleep), **Love**, **Party**, and
  **Sweet**, the pastel one: the ghost in soft pink, lilac, mint, butter and sky with little hearts, flowers and
  sparkles. Sweet is our own ghost in that cute pastel manner; none of Sanrio's characters, names or drawings are in
  it, since those are Sanrio's. The sticker button is in the message field while it is empty; the sheet
  (`lib/ui/sticker_picker.dart`) has a tab for each pack and opens on the one last used, and a tap sends. A sticker
  goes as a picture message (`Sender.sendSticker`: a PNG of 55 to 130 KB, so its clear background survives and any
  phone can show it), which means it is never encrypted, and the sheet says so in an encrypted conversation. Its
  file's name (`ghost-sticker-love-03.png`, `Stickers.kt`) is all that makes this app draw it small on the page with
  no bubble, and call it "Sticker" in the list; any other app shows a picture. 64 stickers, 1.3 MB.
- **Their texts are coming without encryption** (0.7.4; `E2e.arrived`; Matt, 2026-11-14: "we need to be able
  to detect if a user is sending us unencrypted messages and let us know so we can disable it"). Encryption on with
  someone seals what goes to them; if they have turned it off, changed phones or left the app, they cannot read it,
  and until now nothing said so. A text that comes from them plain while encryption is on is counted: the first one
  raises a notification, and the conversation says "Sam's last 2 texts came without encryption…" over its message
  field with Turn off beside it and a cross to put it away (it comes back with their next plain text). A text that
  comes sealed again clears it. The app's own texts (a key, a chat background) count as neither. A conversation's
  settings say the same under Encryption, and so does the Mac, where it is said and turned off from the phone.
- **Videos** (0.7.4; `Video.kt`, `lib/ui/video.dart`, `macos/Runner/DeskVideo.swift`; Matt, 2026-11-14: "mp4
  files are not loading it just shows up as a string of text for the filename"). A video in a message is drawn as a
  picture of where it starts, with Play over it and how long it runs, where it was its file's name and no more. A
  tap plays it: the whole screen on the phone (Android's own player and controls), a window of its own on the Mac
  (the Mac's). The phone makes the picture from the message's own part; the Mac brings the video's bytes over the
  link as it does a picture's, and keeps them in a file only while the picture is made or the window is open (its
  folder in the temporary directory is removed as the app opens and quits). One no picture can be made of (a kind
  the device cannot read) is still named, and can still be tried. Sending a video is not part of this.
  - **Uplink's own player on the phone** (0.7.36; `lib/ui/video_screen.dart`, `videoFile` in `Video.kt`; Matt,
    2026-11-15: "id like a video player built with glacier UI right now it looks like a very old android core system
    player"). On black, a round frosted back button with who sent it, and a frosted dock: play/pause, where it has got
    to, a scrubber, its length, mute. A tap shows or hides the controls (they go by themselves after 3 s while it
    plays); a double tap either side skips 10 s. Played by `video_player` (ExoPlayer) from a file: the MMS part copied
    into the cache, or the one Google Messages' helper brought down. The Mac keeps its own window.
- **What a computer may ask of the phone** (0.7.4; Matt, 2026-11-14: "the desktop app should get all featues
  its missing from mobile", and of the Mac's message field "an emoji picker, file upload, voice memo and sticker
  selector"). The link carries what the phone's screens do: deleting, editing, sending a picture message again,
  blocking, encryption on and off, and pictures, a voice recording and a sticker sent from the Mac, handed to the
  phone in pieces and sent by it once ([docs/desktop.md](desktop.md), "What they say to each other"). The Mac
  has its own panel for choosing pictures, its own emoji, a recorder and a player. A phone with an older app says
  it does none of it, and the Mac offers none (`Sms.can`). The screens do not offer these yet: that is the shared
  shell's to switch on.
- **The Mac app updates itself** (built 2026-11-14; Matt: "install the app on my mac and make sure it has OTA
  updates so we don't need to reinstall again"). It reads `https://ghost-sms.com/mac.json` as it opens and every six
  hours, brings the newer app down, takes it only if it is whole and signed by its own team (Matt's Developer ID),
  puts it beside itself and swaps the two on Restart to update or on quitting. Ghost.md's Mac updater, carried
  over. `node tool/release-mac.mjs` makes a release (`--install`, `--notarize`, `--publish`). Nothing is published
  yet ([docs/desktop.md](desktop.md), "Updating itself").
- **A link in a message opens** (0.7.6; `lib/links.dart`; Matt, 2026-11-14: "I can't click to open links in
  the desktop app"). A link was underlined and nothing more, on the phone as on a computer. Now a press on one
  opens it in the browser: the phone's (`Arriving.openLink`), or the computer's own (`open`, in
  `lib/desktop/remote.dart`). `MessageLink.find` says what a link is (http, https or www up to the next space,
  less the full stop, comma or stray bracket that ends the sentence), and only a web address is ever opened:
  nothing in a text can start another app. A long press is still the message's menu. On a Mac the pointer turns to
  a hand over one. The Mac has it from its first release (0.7.6, 2026-11-14); a press there has not been watched.
- **Pictures that never arrived, on Verizon** (0.7.4; Matt, 2026-11-14, with his phone's report: "Im getting this
  error on freshly sent photos": `not fetched: the carrier no longer has it … (result 4, HTTP 404)`). Verizon
  announces a picture at an address that stops at "=" and serves it only with the announcement's transaction id
  after it; its settings say so (`enabledTransID`), Android's own texting apps add it, and this app did not, so
  every picture sent to a Verizon phone was "not found". Now the id is added where the carrier's settings ask
  (`MmsWhy.fetchAddress`), and where they do not say and the bare address is answered "not found", it is asked for
  once more with the id before anyone is told (`MmsWhy.worthAskingWithId`). Each fetch writes which server was
  asked and how to the Developer log. Reproduced and mended on an emulator against a stand-in carrier that behaves
  that way (`tool/mms/README.md`); not yet seen on Verizon itself. Pictures that failed before can be asked for
  again with Try again, for as long as the carrier keeps them. An error of the app's own in the report
  ("Null check operator used on a null value") said nothing of where: such a line now names where it was thrown.
- **Routes: a relay system that can be swapped** (0.7.4; [docs/network.md](network.md); Matt,
  2026-11-14: "implement a full relay system for the app that's replacable and swappable ... The goal will be to
  have multiple sources to feed data to eachother from wifi locally, p2p, internet, sms, etc"). `lib/net/`: a route
  is one interface (`Carrier`), the switchboard chooses between routes, falls back and seals, and two routes exist:
  the relay server's hub (`relay/lib/hub.dart`: names made from keys, packets held for someone away, who is here,
  rooms to join and leave) and SMS data texts, which no texting app shows and which reach a closed app. The people
  the routes reach are the people encryption is on with. Settings › Network shows each route with a switch, the
  relay server's address, and a test to each person that says which route carried it. Nothing in the app is carried
  by them yet but that test: calls, receipts and the local-network and peer-to-peer routes come next. The hub is
  on our server since 2026-11-14 (`wss://ghost-sms.com/hub`; `tool/deploy-relay.mjs`, `relay/README.md`), tried
  from outside with two made-up installs (`tool/net/live_hub_test.dart`); two real phones through it are not
  yet seen.
- **Invite someone by text** (0.7.4; Matt, 2026-11-14: "Id like to also be able to invite people to join
  ghost messaging over text which would prompt them to install the app"). Settings › Network › Invite someone by
  text opens a new chat with the invitation written (`inviteText` in `lib/ui/network.dart`: what the app is for and
  ghost-sms.com, where it is downloaded); the person chooses who, may change the words, and sends it as any text.
  Once the other has the app and the two text each other, the app's own finding of the other (`GhostMark.kt`)
  offers to turn encryption on, which is what makes them someone the routes reach. Not done: an invitation that
  carries this phone's key, so that the first text from the other phone is all it takes.
- **One frame, phone and computer** (0.7.4; `lib/ui/shell.dart`; Matt, 2026-11-14: "Unify the UI experience
  to match on desktop and mac as well the desktop app should get all featues its missing from mobile and thr mobile
  app should gain the nav from desktop"). `AppShell` is the list of conversations and a pane for what is opened from
  it. In a window 640 wide or wider (a folding phone opened out, a tablet, a computer) the list is down the side,
  as the Mac's first had it, with what is open beside it, its row marked, and no way back drawn; narrower (a phone,
  a folding phone's cover) the list is the screen and what is opened slides over it. Both are kept in place as the
  window changes, so a conversation open on the cover, and what is half written in it, is still open when the phone
  is opened out. The way round is the Mac's pill floating at the list's foot (`lib/ui/nav_bar.dart`: a new chat, the
  messages, the contacts, the archive with its number, Settings), where the phone had a round "New message" button,
  Settings in the header and Archived as a row at the list's end. Android's back closes what is in the pane, then
  leaves the archive, then leaves the app. What a notification
  or another app's "text this number" asks for opens in the pane too. The Mac's window is this same frame
  (`lib/desktop/ui/shell.dart` is a few lines now): `AppShell` takes what the Mac keeps
  under its search field (`status`), what its pane says when empty (`nothing`) and its own Settings (`settings`).
  What a screen offers on a computer is what the phone it is paired with says it does for one (`Sms.can`):
  pictures, stickers, voice messages, editing, deleting, blocking, encryption's choices; a phone that is behind is
  offered none of them.
  A held message's effects are behind an item of its menu, Effects, which opens them by name in the menu's place
  (Matt: "Message effects should be under a literal effects item on thr message context that opens a sub context
  to the effects not a row of effect icons").
- **The list's tabs** (0.7.10; Matt, 2026-11-14: "add a right click menu for the codes and messages tabs as
  well as a button to mark all read and change the messages and codes to a segmented toggle"). Messages and each
  section a plugin makes (Codes, Spam) are one segmented toggle under the search field (`SectionTabs` in
  `lib/plugins/ui.dart`), where they were chips in a row. Beside it, Mark all read marks every unread conversation
  of the tab shown (`MarkAllRead`; quiet while nothing there is unread, and standing alone where there is no
  section to make a tab of). A press with the other button on a tab, or a long press, brings up that tab's menu:
  Mark all as read, and Select all, which chooses every conversation of the tab for the bar at the top to archive
  or delete. Since 0.7.11 (Matt, 2026-11-14: "change mark all as read to just be the icon in a
  circle button", "the segmented toggle for messages vs codes can be a size larger") the button is its picture
  alone in a circle as tall as the toggle, with its words in a tip under a resting pointer (`HoverTip` in
  `lib/ui/nav_bar.dart`, the pill's own tip made public), and the toggle is the kit's middle size.
- **The Archive and Settings rings' menus** (0.7.11, small since 0.7.12; `lib/ui/nav_bar.dart`
  `NavItem.menu`, `_archiveRows` / `_settingsRows` in `lib/ui/shell.dart`; Matt, 2026-11-14: "add a right click
  context menu to archive as well and settings to quick jump to settings sections", then of the sheet across the
  window's foot it first was: "too large and way too wide", with a picture of a small list hung by its button).
  A press with the other button on either ring, or a long press, hangs the kit's menu (`GlacierMenu`) over the
  ring: twelve to fifteen rems across, its right edge on the ring's, no taller than the window has room for, with
  more rows than that scrolling inside it. Archive's: how many are archived, Mark all as read (every archived
  conversation that is unread, with the archive left closed) and Select all (the archive opens with everything in
  it chosen, for the bar at the top to take back out or delete: `ConversationsScreen(archived: true, selectAll:
  true)`). Settings': its sections by name, as they stand for this device and these choices, in their groups
  under the groups' names (`settingsGroupLabel`; a section alone in its group has none), each opening Settings at
  that section; its row in Settings' list is brought into view where it was out of sight. The list's tabs' menus
  are still the sheet.
- **Calls as a list, ripples, a dock, three list layouts and a call capsule** (0.7.22; Matt, 2026-11-15:
  "make the voice chats a list of participants don't show the squares unless someone turns on video and make the
  profile picture habe wobbly ripples going out when talking ... voice controls at the bottom in a dock ... an icon
  only segmented toggle ... add voice chats to the list as well, try a few different layouts ... including a mixed
  view ... rework the active call indicator").
  - A call is everyone as a list (`CallPanel`), a picture only for whoever has video on, and the buttons in a dock
    at the foot (`CallDock`). Faces ripple with wobbly rings while their owner talks (`lib/ui/ripple_avatar.dart`),
    from WebRTC's audio levels read several times a second (`RtcMedia.levels`). The browser page does the same.
  - The list's toggle is three icons: Messages, Codes and Voice, the channels (`VoiceRow`, live in green), always
    there ("use the segmented toggle with the three icons instead of intertwining them remove the other options for
    now"). The pill has five rings again: calls are the Voice tab ("lets remove the calls icon in the dock").
  - While in a call your face floats over the list's corner, rippling as you talk, ringed green, marked red when
    muted (`CallBubble`; "the active call floating in a single avatar with our speech wobbles coming out"); a press
    opens the call.
  - Press and hold someone in a call (or press with the other button) for: Mute for me (silenced here only), their
    volume here from nothing to 200%, Add as a friend where they have a username (members now say theirs), and Copy
    name; for yourself, mute and deafen. Each person's volume and mute are kept and applied in every call
    (`Voice.setVolume`/`setSilenced`, `RtcMedia` with WebRTC's per-track volume).
  - A paired computer's voice channels are the phone's (`Voice.answerDesk` on the phone through android DartAsk
    "voice"; `Voice.syncNow` on the computer, at once and every eight seconds): the phone's groups' channels and its
    own, its name and username to go by; a channel made or removed on the computer is made or removed on the phone.
  - The new ring asks: a new chat, a new group, or a voice call, which names the channel, shares it with friends you
    pick and puts you in it ("The new button should also ask for new chat, group or voice call").
  - In a call the Voice page is the call alone: who is in it as plain rows, not in a card, and the dock ("I want the
    call screen to be super simple too just a list of chatters and the call controls", "Make the lists of people not
    in a card"); a picture only appears for someone who turns video on.
- **Hangouts by link, in a browser** (0.7.22; site/join; Matt, 2026-11-14: "Make the voice hangouts
  possible to share via a link so people can join to talk anonymously or sign up through the browser similar to a
  zoom meeting"). A hangout's options (and the call, for one that is not a group's) copy
  `https://ghost-sms.com/join/#<seed>.<name>`: the seed is after the #, which a browser sends to no server. The page is
  a member of the channel in the browser, the app's protocol written again in JavaScript (`site/join/voice.js`):
  who is there before joining, a name or "Guest", microphone and camera, then the call with its tiles, mute, video
  and leave. Sign up claims a username on the relay for a key kept in the browser (IndexedDB, not readable even by the
  page). Guests are marked in the app's call. `tool/voicebench/join_test.mjs` runs two browsers through it against a
  local relay (sound and video both ways, the same room and token as the app). Not yet: a TURN server, so two people
  on strict networks may not connect; friends and messages in the browser.
- **Bigger count badges** on the pill's rings and the filter (24 px, 13 pt; "make the notification count badges a bit
  bigger on the filter and other places where they're listed").
- **Uplink for Windows, and Mac and Windows downloads on ghost-sms.com** (2026-11-15; Matt, 2026-11-14: "Add a
  mac and windows build to ghost-sms.com"). The desktop app builds for Windows (`windows/`, built on GitHub's Windows
  runners by .github/workflows/messaging-windows.yml, which also installs it silently and checks it opens a window)
  into an Inno Setup installer (`windows/installer.iss`: per person, no administrator, Start menu, uninstaller).
  `tool/release-windows.mjs` starts that build and puts `ghost-messaging-setup.exe` and `windows.json` on the site;
  0.7.21 (35 MB) was the first, unsigned, so Windows asks once before running it. On Windows the pairing is kept in
  %APPDATA%, the phone is found by its address or the relay (no Bonjour), the Mac's updater is off, and the screens say
  PC. The site has Download for Mac and Download for Windows under Android's, each shown once its feed exists.
  Not yet: Windows updating itself, a signed installer, voice messages recorded on Windows.
- **gogho.st** (0.7.26, not released; site live 2026-11-15; Matt: "I got the domain gogho.st hooked up the box,
  please update all the links in app and everything to point through that domain instead of the ghost-sms one also
  point that domain to the website"). The site is at gogho.st (www redirects to it), and the app's updates (phone,
  Mac, Windows), the hub, the computer link's relay, hangout links and the invite all point there.
  ghost-sms.com still serves what copies installed before the move ask of it (their update feeds, /hub, /relay)
  and the sign-in pages at /link/*; every other address there redirects to gogho.st (tool/deploy-site.mjs).
  Kept on purpose: `@group.ghost-sms.com` in a group's address (a name phones store and send, not a link), and the
  relay's sign-in callbacks (`GHOST_PUBLIC_URL`), until gogho.st's callback addresses are added at Discord, X and
  Telegram. The folders on the box keep their names (/opt/ghost-sms-*).
- **Add a friend from a drawer beside Contacts' search** (0.8.1, not released; Matt, 2026-11-16: "move the Add button
  to the side of search and have it open a drawer to search and add users as well as setup username if hasn't been
  done already"). A round Add beside the search opens it: without a username of your own it asks for one first; with
  one it looks up an @username as it is typed (whole names only, never listed by their start) and offers Add, or
  Accept where they asked you (lib/ui/add_friend_drawer.dart). The requests and friends stay at the top of Contacts.
- **Mark all read covers Telegram and Signal** (0.8.0; Matt, 2026-11-16: "The mark read button should
  work for telegram and signal as well as standard messages"). The button counts the tab's unread chats from every
  network with its unread texts, so it is no longer grey when only chats are unread, and reads them all; a network's
  own tab and its menu read that network's chats (`_unreadTexts`, `_unreadChats` in lib/ui/conversations.dart).
- **Mentions in spaces and circles** (0.9.20, not released; Matt, 2026-11-19: "Add mentions support to spaces and
  circles with the @user prefix"). "@" at the start of a word in a space's chat opens a list over the composer of the
  space's people (its members list, whoever wrote there, and in a circle everyone seen in it), narrowed as the name is
  written and best first: a name that begins with it, then a later word or a username, people here now, then whoever
  wrote last. A press, or Enter or Tab on a keyboard, puts in "@Name"; the arrows choose, Escape closes it. The
  message carries who each "@Name" means beside its words (`mn`: `[start, length, id]`, counted in the words), so a
  build from before reads the words as they are and two people of one name are told apart; a mention is believed
  only where the words show it at an "@" (`Mention.checked`), so nobody is called by one hidden from the reader.
  Typing into a mention makes it plain words; a backspace into one takes all of it (`MentionEdit`). A mention is drawn
  in the accent and pressed for who it is, with Mention them back; a message that mentions you has the accent's bar
  (a circle's channel) or rim (bubbles); an unread mark reads "@" where something unread mentions you; and on the
  phone a mention is notified, opening its space (Settings › Notifications › Mentions in spaces; a space's other
  messages still don't notify). Someone's phone and paired computer are one person: a mention of either reaches both,
  known by their username (`HangoutRoom.mentionsMe`). lib/mentions.dart, lib/ui/mention_field.dart,
  lib/voice/mention_alerts.dart. Not done: @everyone and roles; a notification while the app is closed (the relay
  holds a space's messages for nobody in particular); a computer's or iPhone's own notification.
- **Spaces in Messages; a group's space is its conversation** (0.8.10, not released; Matt, 2026-11-17: "each group
  should come with a space but I'd also like spaces to show up in the main chats list with a preview of the last
  message sent in the space"; he chose one chat per group, staying connected for previews, and side by side when wide).
  Each space is a row among the conversations, newest message first ("Riley: Yes! Bring your notes"), with its unread
  mark and, while anyone is in its call, a green headphones count where the time goes; Mark all read reads spaces too.
  The app stays in every space's chat room while it runs (`Voice._listenAll`, `unreadIn`, `markRead`), and a room the
  relay dropped asks again for what it missed once back (`HangoutRoom._event`). A space opens as a chat with Join voice
  at its top; on a phone, with people already talking in it, it opens on who is in the call, tapped to join, with the
  chat a switch away. A group of friends is its own space: its conversation's row shows its call's count, a pill with
  who is in voice and Join floats at the top of the conversation (`SpaceLiveBar`), and the group in the Spaces tab
  opens the conversation.
- **Invite people into a space from the app; the chat bar above the keyboard** (0.8.2, not released; Matt,
  2026-11-16: "also make a way to invite friends from the app into spaces and invite people into spaces through the
  app"; "the chatbar doesn't move up when in the chat section of a space"). Every Invite (each call design, the space's
  page, its menu's "Invite people", its settings) opens one sheet, `showSpaceInvite` (`lib/ui/space_invite.dart`):
  friends on Uplink to tick and send (`Voice.share`), and for anyone else "Text an invite" (a new text with
  the link written in), "Copy invite link" and "Share link…". A friend sent a space sees "<name> invited you to
  <space>" with Join and Not now (the ring card). Only roles that may invite see it, and a group's call is never
  offered. In the Voice chat design's chat on a phone the message bar now stands just above the keyboard.
- **Voice chat is the default space call, in the app's own look** (0.7.49, not released; Matt, 2026-11-16: "Change
  the telegram one to be our colors without the gradients and our voice effects make the chat window 33% of the screen
  as well then deploy this as the default version"; "Make a few other small tweaks to make it ours and less like
  telegram"). `SpaceDesign.fallback` is the Voice chat design (`lib/ui/space_designs/telegram.dart`); Standard, the
  earlier layout, and the other five stay in Settings › Developer. It now follows the app's light and dark colours,
  flat with no gradients (a test reads the file to keep it so), the app's wobbly ripples on every face and round the big
  mic button, the chat docked at exactly a third of a computer's window (a sheet on a phone), and the app's words and
  pieces: the space's name with "N in voice" as its title, "talking", "Mic on" / "Muted", "Invite to space", the app's
  RoleTag, no Telegram drag handle. Built, reviewed adversarially, fixed and checked again in two passes.
- **Six other designs for a space's call, behind a developer switch; your own voice activity alone** (0.7.49, not
  released; the switch and all but one of the designs **removed 2026-11-24**, Matt: "remove the other video call
  layouts from the codebase we only use the default one now": Voice chat, the default since 2026-11-16, is how a
  space's call is drawn, and `lib/ui/space_designs/` holds it, the call's model and the plugins' places alone; Matt,
  2026-11-16: "give me 6 alternate designs for the calling chat and video screens for spaces,
  Additionally make it so that even when we're in the call alone we see the voice activity of ourselves release all 6
  versions under a developer setting flag so I can toggle them on and off. Use iconography and good labeling and base
  the designs off popular voice and video chat apps that exist today").
  - **The switch:** Settings › Developer › Space call design: Standard (the app's own) or one of six. With one chosen,
    a space's call opens as a page over the whole window (`openSpaceCall`, `SpaceCallPage`); Minimise puts it away to
    the call banner, which brings it back.
  - **The six** (`lib/ui/space_designs/`): Voice channel like Discord (dark tiles, green outline on whoever talks,
    Text in voice panel), Meeting like Zoom (speaker and gallery views, labelled toolbar, Participants and Chat
    panels), Full screen like FaceTime (whoever talks fills it, you in a corner, glass controls), Rounded tiles like
    Google Meet (audio bars, pill toolbar, People and In-call messages), Audio stage like Clubhouse and X Spaces (big
    rippling faces on stage, listeners below, chat as Comments), Voice chat like Telegram (a dark sheet of people with
    waves, one big microphone button). Each works on a phone and a computer window, light and dark, with an icon and
    words on every control (`SpaceWords`, the same words in all six), and draws from one model, `SpaceCall`.
  - **Built** by six agents in parallel, each design then reviewed adversarially against its brief, fixed and
    checked again (tests: `space_design_<name>_test.dart` for each, `space_designs_test.dart` over all, pictures
    `test/shots/space-*`).
  - **Your own activity alone:** the level meter (`RtcMedia`) is now connected to a silent partner on the device, so
    the microphone really sends and is measured with nobody else in the call; what arrives at the partner is never
    played. Not yet heard on a phone or the Mac.
- **Hangouts get a chat, and roles and permissions as Discord has them** (0.7.25; Matt, 2026-11-15:
  "Implement a permissions system similar to discord for hangouts and add a chat to hangouts so the whole group can
  send messages to the hangout as well as voice and video, make default roles such as admin, moderator, member").
  - **Owner.** A hangout made now carries its maker's public key (`VoiceChannel.owner`, in its link as a third part
    after the name, in the phone ⇄ computer sync and when shared with friends). The owner can do everything and can't
    be acted on. Hangouts made before this have no owner: everyone in them is a member and nothing can be changed.
  - **Roles** (`lib/voice/roles.dart`): Admin, Moderator and Member to start, each a set of permissions (Speak,
    Video, Send messages, Invite, Mute others, Remove people, Ban, Manage messages) and a rank; a role acts only on
    those below it. Admins edit what each role may do, add roles (above, between or below Moderator and Member),
    assign every role but admin, and choose the role new people join as. Only the owner makes admins.
  - **How everyone agrees without a server.** One `Roster` per hangout: numbered and signed by whoever changed it.
    A device keeps the highest-numbered roster it can check: signed by the owner, or by an admin whose being one the
    owner signed (`adminGrants`). Anyone in the hangout can hand it to a newcomer; no one else can forge one
    (hangout_test: a member's self-promotion, an altered roster, a copied grant, all refused).
  - **The chat** (`lib/voice/hangout.dart`): a second hub room beside the call's (`VoiceChannel.chatRoom`), sealed
    with the same key, joined while the hangout's page is open or you are in its call, so people out of voice can
    write too. The hub keeps nothing: each device keeps the last 300 messages, and someone coming in gets what they
    missed from the lowest id there (one copy, not one from everyone). Delete your own; Manage messages deletes
    those of roles below.
  - **Enforcement, on every device.** A message from a role that may not write is not shown. Someone muted for
    everyone (in the roster by an admin, or by a moderator while they are there) is silenced on every device and
    their own microphone is locked; a role without Video can't turn the camera on. Remove puts someone out now (they
    can come back); Ban is in the roster, so they are refused in the call and in the chat for good.
  - **Pages** (`lib/ui/hangout_screen.dart`): a hangout opens its page: who is here, Join voice, and the chat. In the
    call a toggle switches between people and chat. Roles show beside names; press and hold someone for their role,
    Mute for everyone, Remove and Ban, as your role allows. The shield opens Roles and permissions.
  - **Layout** (Matt, 2026-11-15: "When opening a hangout the left side should show the chat with some space below
    reserved for the navbar controls, the voice on desktop should show up on the left side with the right side reserved
    for chat, when a video starts split the right side 50/50 showing the videos above the chat"). A hangout opened from
    the list is in the list's place, its composer and dock standing above the pill (`HangoutScreen.inSidebar`). Beside
    the list (a computer, the Fold open) the call is the people and the dock there, and the pane is the chat
    (`HangoutStage`), whose top half becomes the videos (`CallVideos`) once anyone turns one on.
    Then (Matt: "clicking on a voice chat should show me the chat in the normal spot and connected participants with a
    "join" button ... hide the default navbar when in a hangout and show the call controls where it was"): a hangout
    pressed in the list opens where a conversation opens (`Voice.view`, VoiceScreen), with who is connected and Join
    voice at its top. In its call beside the pane, the people take the list's place (`HangoutPeople`) and the call's
    dock stands where the pill was; the pill comes back on leaving.
  - **Called "spaces" now** (Matt, 2026-11-15, picking from suggested names: "Space"). Everything people read says
    space: the Spaces tab and page, New space on the new button, Space settings, Delete space, Remove from space,
    a group's Group space, the walkthrough's calls page (re-voiced), the landing page and the join page ("Join a
    space"). Code names (`VoiceChannel`, `HangoutRoom`, `hangout_screen.dart`) and what goes over the wire ("hangout
    room", the roster's signed "ghost-hangout" text, link format) stay as they were, so links and rosters keep working.
  - **Menu and settings** (Matt: "a context menu to open settings for hangouts and manage permissions and such as well
    as delete the hangouts"): hold or right-click a hangout's row for Open, Settings and permissions, Copy invite link,
    Share with friends and Delete hangout (asked first; `showHangoutMenu`). Its settings page
    (`HangoutSettingsScreen`) is the link, sharing, the owner, the roles and permissions, and Delete.
  - **The browser** (site/join): the same chat beside the call, role tags, and the same rules. It checks rosters
    itself (P-256 by WebCrypto; tool/voicebench/roster_check.mjs checks rosters the app signed) and leaves when
    removed or banned. tool/voicebench/join_test.mjs covers the chat both ways and history for a latecomer.
  - **Not yet:** a moderator's mute is held only while they are in the hangout; the site's join page needs
    `tool/deploy-site.mjs` to go live. (A phone and its computer are one person in a hangout since 0.9.20.)
- **Delivery to friends: sent again until answered; the relay connection made again on coming back** (not
  released; Matt, 2026-11-16: "Yes, fix delivery"). A message the relay server had handed to a connection of the
  friend's that had just died (the app in the background) was lost with nothing to say so.
  - `Friends` keeps what went out and has had no answer (`friends_out`, so a closed app goes on after) and sends it
    again with the same envelope id: twenty seconds after, then twice as long each time up to five minutes, and at
    once whenever the routes change; after three days it is marked failed. The friend's app keeps the ids it has
    stored (`friends_in`, the newest 500), so a message whose answer was lost is not kept twice.
  - Back on the screen after 45 seconds or more away, the app makes the relay connection again rather than trust one
    the phone may have let die, and one that is down is tried at once rather than at the end of its wait
    (`HubCarrier.nudge`, `Net.resume`, main.dart's lifecycle).
  - Checked by tests (a route that swallows a message, a restart in between, a local relay dropped and back); the
    iOS Simulator keeps a backgrounded app's connection alive, so the dead connection itself was not reproduced live.
  - Not yet: groups of friends are not sent again (Groups.sendText). A closed app is woken by the entry above.
- **Matrix, WhatsApp, Microsoft Teams and Google Chat** (not released; Matt, 2026-11-17: "Let's add support for
  matrix, microsoft teams and google chat, enable whatsapp but warn the user that it's unsupported by whatsapp").
  Each is an `InboxNetwork`: its chats among the texts with its mark, read and answered here, between the device and
  that network only.
  - **Matrix** (`lib/inbox/matrix.dart`, helper `sidecar/matrix` on mautrix-go v0.33 with goolm's encryption, pure Go;
    `tool/build-matrixsidecar.sh mac|android|windows`): any homeserver or user id (`.well-known`), sign in with the
    browser (SSO to a 127.0.0.1 listener, which matrix.org's authentication service allows) or a password; encrypted
    rooms decrypt and sends are encrypted; the recovery key, optional, verifies this device and restores the key
    backup so older messages open. DMs and groups, replies, reactions, deletes, files both ways, invites. Blocking is
    Uplink's own list.
  - **WhatsApp** (`lib/inbox/whatsapp.dart`, helper `sidecar/whatsapp` on whatsmeow, MPL-2.0;
    `tool/build-whatsappsidecar.sh`): linked as a device the way WhatsApp Web is, by QR code or WhatsApp's 8-character
    phone-number code; WhatsApp's history sync brings recent chats. **The warning** (`whatsAppWarning`): WhatsApp
    doesn't allow other apps and may suspend or ban accounts it finds on unofficial ones. The link screen opens on it
    and asks for nothing until "I understand, link WhatsApp" is pressed; WhatsApp's Settings section shows it too.
  - **Microsoft Teams** (`lib/inbox/teams.dart`, Microsoft Graph, pure Dart): device code sign-in, work and school
    accounts only (Graph's chats don't serve personal accounts); chats polled every 30 s (the open one 6 s, 429s
    honoured), send, reply, react, mark read, delete own, inline pictures. "Not in this build" until built with
    `--dart-define=GHOST_TEAMS_CLIENT_ID=…`: an Entra app registration (multitenant organisations, public client flows
    on, delegated `offline_access User.Read Chat.ReadWrite ChatMessage.Send`, no secret).
  - **Google Chat** (`lib/inbox/google_chat.dart`, the Chat API, pure Dart): Google's consent page with PKCE and a
    127.0.0.1 redirect; Google Workspace accounts only; DMs, group chats and spaces, thread replies inline, send, reply
    into a thread, react, mark read, delete own; names through the People API. "Not in this build" until built with
    `GHOST_GCHAT_CLIENT_ID` and `_SECRET` (a Google Cloud project with the Chat and People APIs, a configured Chat app,
    the consent screen and a Desktop OAuth client). `chat.messages` is a restricted scope: offering it to everyone
    needs Google's verification; until then, up to 100 test users.
  - Releases pack the Matrix and WhatsApp helpers into the Mac app (Contents/Helpers, signed) and the phone's jniLibs,
    beside Signal's (about 12 and 15 MB on a Mac, 11 and 17 MB on the phone). Windows carries neither yet, as it
    carries no Signal helper.
  - Checked: each against stand-ins (Matrix 8 tests, WhatsApp 4, Teams 5, Google Chat 4) and the helpers' own `go
    test`; the Matrix helper found matrix.org's server and its sign-in ways live, the WhatsApp helper got a real QR
    code from WhatsApp. Not yet tried with a real account on any of the four.
- **A closed app woken when a friend writes** (not released; Matt, 2026-11-16: "Yes, wake-ups", "Check every ~15
  min"). What friends by username write waits on the relay server while the app is closed; now the app hears of it.
  - **iPhone**: after the welcome the app asks once whether it may show notifications, and says Apple's push token
    over its hub connection on every sign-in (`lib/standalone/wake.dart`, `HubCarrier.push`, `Net.setPush`,
    ios/Runner `pushRegister`, `Runner.entitlements` with `aps-environment`). When a packet is held for it the relay
    server asks Apple to show "New message", at most once a minute (relay/lib/pushes.dart: `pushes.json`, an ES256
    token signed with the relay's own P-256, sent by `curl --http2`; a token Apple no longer knows is forgotten).
    The notification says only that something came.
  - **Android**: Android's own JobScheduler, about every fifteen minutes (no Google services, no library): signs in to
    the hub only to look (`HubPeek.kt`; the hub's `peek`, which says how much is held and hands over and takes
    nothing) and shows "New message" when more is held than it last said. Not while the app is open or with no
    friend by username. The hub's greeting says `peek: true`; a hub that does not is not signed in to, since an
    older one would hand everything over to the look.
  - **Needs, to go live**: the relay deployed (`tool/deploy-relay.mjs`), and for iPhone an APNs key from the Apple
    Developer account (Keys › +, Apple Push Notifications service: the .p8 file and its key id; Push Notifications
    on the App ID) set on the box as `GHOST_APNS_KEY_FILE`, `GHOST_APNS_KEY_ID`, `GHOST_APNS_TEAM_ID=F6ZAL7ANAD`.
    Without the key the relay keeps tokens and sends nothing.
  - Checked: relay tests (a look counts without handing over, a look leaves the app's own connection be, a token
    kept, forgotten and rate-limited, the JWT checked with the key's public half, a real openssl-made .p8 read), app
    tests against a local hub (`push_wake_test.dart`), Android's look against a written-out hub and a real local
    relay (`HubPeekTest`), and the iPhone Simulator asking and getting an 80-byte token from Apple. Not yet seen: a
    real notification arriving (needs the key and the deploy).
- **Friends by username on Android: iPhones and Android phones text each other** (not released; Matt, 2026-11-15:
  "Yes, Android next").
  - Android's store of texts has no room for someone with no number, so a friend by username's conversation is kept
    in Dart (`lib/standalone/chats.dart`, `UsernameChats`, the same store the iPhone uses) and `OverlayCalls`
    (`lib/standalone/overlay.dart`) stands in front of the phone's channel: what is about an `@username`, or a
    conversation or row it keeps (ids from 2^40), is answered there; the list, contacts search and encryption states
    are the phone's with these added; everything else goes to the phone. `Sms.remote` stays false behind it
    (`PhoneSide`).
  - android Buddies.peers gives a friend who said yes the address `@username`, so `Friends` carries their words.
    A message from them is notified by `Notifier.chat` (Android's own notifications see only its store). No phone
    call button for them, and no wake text (they have no number).
  - Checked live, Android emulator and iPhone Simulator over the relay: a request each way, a message each way,
    delivered, shown in the open conversation and in the list beside texts.
  - Not yet: a paired computer does not see these conversations (it asks the phone's Android side); a message the
    relay passes to a connection that has just died is lost, as for any friend (nothing is sent again without an
    answer); a closed or backgrounded app hears them only when it connects again.
- **Friends by username on Contacts, and friend requests** (0.7.49; Matt, 2026-11-16: "We need a way
  to add friends on the network by username on the contacts page and see friend requests"). At the top of Contacts
  on the phone (`UsernameFriends`, lib/ui/username_friends.dart): a field to ask someone by @username, each request
  with Decline and Accept on it, friends by username, and the requests you sent (a press takes one back); without a
  username of your own, a row to choose one. The dock's Contacts ring counts the requests waiting. The relay is now
  kept for friends by username from the moment you have a username (lib/main.dart), not only once you have a friend,
  so a first request reaches you. Not yet: a chat with a friend by username on Android. Tests: buddies_test's
  "on Contacts" group; screens_test's `15-contacts-friends` picture.
- **Uplink on iPhone, without SMS** (not released; Matt, 2026-11-15: "port the app to work on iOS as well,
  investigate if we can within apples rules make a bridge for messaging through RCS like we're doing with mautrix on
  android and if not we'll want to roll a version of the app that works without sms"; "it's unlikely the user will
  ever have two phones").
  - **What Apple allows**: no app may read or send texts on an iPhone, except in the EU, where iOS 26's
    TelephonyMessagingKit lets the person's chosen default messaging app do so (with an entitlement Apple grants).
    The Google Messages bridge (mautrix-gmessages, as Beeper uses it) works only by pairing with Google Messages on
    an Android phone. So an iPhone of its own has no texts: friends by username, groups and calls over the relay.
  - **The iPhone app** (`lib/standalone`): `StandaloneCalls` answers the phone's calls by the same names from a store
    of its own (Application Support, `standalone.json`), so the phone's screens and start-up run unchanged
    (`Sms.standalone`). Its identity is a P-256 key made on the iPhone (Keychain in a release build), the same
    arithmetic as the phone's (`NetKeys`), so an iPhone and an Android phone seal to each other. Each friend by
    username is a conversation addressed `@username`, carried by `Friends` as a phone-number friend's is.
  - **First screen** (`StandaloneWelcome`): a username, claimed on the relay's directory, and a name for friends.
    No pairing step. An iPhone already paired with an Android phone as a computer stays its companion.
  - **`Sms.remote` split**: `Sms.paired` (asks a paired phone: computers, a paired iPhone) and `Sms.computer`
    (a window's sizes) beside it; `remote` still means no texts here.
  - **Native half** (`ios/Runner`): DeskChannels, DeskSound, DeskVideo and VoiceFx from the Mac, for UIKit (Keychain,
    Bonjour, the photo picker, the audio session, iOS's video player, voicefx in WebRTC's capture hook).
  - Checked in two iOS Simulators against the live relay: usernames claimed, a friend request sent and accepted
    (sealed), a message sent, delivered and shown unread on the other. Not yet: groups and pictures from an iPhone, a
    friend by username on Android (Android has no username chats yet), push notifications, TestFlight.
- **The walkthrough, as Ghost Keyboard's and Ghost.md's** (0.7.26; Matt, 2026-11-15: "Look at how we do onboarding
  on Ghost KBD and Ghost Markdown with the optional voice guide through the elevenlabs key and the vibrant colors and
  iconography for each step, mimick this on the setup of Ghost Messaging"). `lib/onboarding`: each page a band of
  vivid colour with its sign and four drifting glass tiles (band.dart, Ghost.md's `HueBand` by way of Uplink
  Keyboard), a title, its words, and its step; dots and the Next button take the page's colour.
  - **Six pages, Uplink as one messenger** (0.7.27; Matt, 2026-11-15: "Rework the onboarding to be a bit
    shorter and have it focus on the fact that ghost is an all in one messenger look at branding from things like
    discord telegram etc and find our own voice amoung those"): Everyone, in one place · Start with your texts ·
    Texts and chats, side by side · Drop in, out loud · On every screen · You're in (a look, then "Say hi"). The
    voice: where Discord is a loud hangout, Telegram fast and powerful, Signal principled and WhatsApp plain, Uplink
    is calm and sure of itself, in short sentences with a little wit; "all your people, one quiet app". Contacts and
    notifications are asked for as the app opens, as before the walkthrough.
  - **Start with your texts** is the old setup screen as a step (`TextsStep`, lib/ui/setup.dart): the default SMS
    app, or beside Google Messages, and RCS first where it is coming from another app. Next waits there, and Skip
    appears, only once Uplink can send texts.
  - **The voice** is ElevenLabs' (Jessica, Eleven v4), made once at build time with the key in ~/.elevenlabs-key by
    `tool/onboarding_voice.py` from narration.dart, kept as assets/onboarding/*.mp3 (420 KB, 52 seconds); only a
    page whose words changed is spoken again. Played on the phone by GuideVoice.kt; Voice on and off at the top, kept.
  - Shown on first launch until finished; Settings › About › Watch the walkthrough again. Tests: onboarding_test
    (the voice per page, Skip, words matching their voice), screens_test's `0-guide-*` pictures.
- **Calls: 4K, Music mode, volume to 200%, RNNoise and DeepFilterNet** (0.7.25; Matt, 2026-11-15:
  "can we support 4k? and flac audio? also build in like krisp noise supression or other fancy noise suppression
  tools, add a volume slider for input and output volume with overboosting", then "RNNoise + DeepFilterNet").
  - Settings › Voice and video (`lib/ui/voice_pane.dart`, `VoiceSettings`): microphone and output volume, 0 to 200%;
    noise suppression Off, Standard (WebRTC's), RNNoise, or DeepFilterNet (computers); Music mode; 4K among the
    video choices.
  - **4K**: the whole picture at up to 25 Mb/s to one other; to more, each copy the size 1080p would send
    (`VoiceSettings.sendTo`). It needs a camera that films 4K.
  - **FLAC** is not something WebRTC carries. **Music mode** sends the microphone as it is instead: no echo
    cancellation, noise suppression, gain control or high-pass filter, 510 kb/s stereo at a constant rate.
  - **Noise and the microphone's boost** are `native/voicefx`, one C library in flutter_webrtc's capture hook on
    every platform (its README has the table): RNNoise 0.2 everywhere, DeepFilterNet 3 on the Mac and Windows
    (`native/voicefx/deepfilter`, a Rust crate with the model built in). On this Mac DeepFilterNet takes steady noise
    down 43 dB at 3% of one core, RNNoise 79 dB at under 1%. Where a choice cannot run, WebRTC's own stands in.
  - **Output volume** multiplies each person's own volume (`RtcMedia._apply`).
  - Volume and noise suppression change in a call at once (`Voice.settingsChanged`); the rest from the next call.
  - Not yet heard in a real call on a phone or a computer: the hooks are built and the engine is tested on its own.
- **The active call is a banner again, just above the dock; the call controls are the dock's size** (0.7.25; Matt, 2026-11-15: "switch the active call to be a banner again in the sidebar just above the navigation
  bar"; "the call controls are also too large they should match the size of the sidebar control dock").
  `CallBanner`; `CallDock` uses the dock's ring size, frosted pill and gap, at 0.8 on a computer as the dock is.
- **"Tell friends I'm here" works from a computer** (0.7.24; Matt, 2026-11-15: "tell friends i'm here
  toggle isn't working on mac and windows only on mobile"). It was turned off on a computer; now it is the phone's
  setting changed through the phone (`Me.setListed` asks `Me.forComputer` "listed", and "state" says it), moving
  at once and going back, with the phone's reason, if the phone refuses or cannot be reached. The phone needs 0.7.24
  too.
- **Uplink for Windows updates itself** (0.7.24; Matt, 2026-11-15: "also we need an auto
  updated for windows"). The Mac's updater (`lib/desktop/updates.dart`) with Windows' own half,
  `WindowsUpdateHost`, in Dart alone: it reads `ghost-sms.com/windows.json` as the app opens and every six hours,
  brings the installer down, holds it to the size and SHA-256 given there, and Restart to update runs it with
  `/VERYSILENT` and quits; installer.iss reopens the app after a silent install. Only a copy in
  `%LOCALAPPDATA%\Programs\Ghost Messaging` built with a build number (`--dart-define=GHOST_BUILD`, set by
  messaging-windows.yml) looks. The installer is unsigned, so it is believed for coming over HTTPS from ghost-sms.com
  and matching its description, not for a signature. Copies of 0.7.23 and before have no updater: 0.7.24 is installed
  by hand once.
- **Voice settings, and device pills on the mic and deafen buttons** (0.7.24; Matt, 2026-11-15:
  "update the UI on phone and desktop to be able to have voice settings to change all kinds of things like bitrates
  and sound input devices etc etc, on the microphone icon and the deafen icon make them pill shaped with a little
  chevron facing up that opens a popover to select input and output devices respectively"). Settings › Voice and
  video (`lib/ui/voice_pane.dart`, `VoiceSettings` in `lib/voice/voice_settings.dart`): microphone and speaker,
  audio bitrate (510, 256, 128, 64, 32 kb/s), stereo, echo cancellation, noise suppression, automatic gain, and the
  largest video sent (1080p, 720p, 480p). In a call the mute and deafen buttons are pills with an upward chevron
  (`DevicePill`); the chevron opens a menu above it of input or output devices and "Voice settings…". A new input
  replaces the track in every connection at once (`RtcMedia.setInput`). Suggested replies have a gap below them
  over the composer (Matt: "there needs to be a gap below the suggested responses").
- **The pill shrinks as Ghost.md's dock does; your own ripples; larger faces on a computer** (0.7.23;
  Matt, 2026-11-15: "Make the dock slightly larger when scrolled to the top of the page and make it get smaller when
  we scroll down just like ghost markdown does match the sizes"; "on desktop it doesn't seem like when i'm talking i
  see the wobbles coming from my voice chat, also make the voice chat avatars a little larger on desktop"). The pill
  is its whole size at the list's top and 0.8 once the person scrolls down, whole again only back at the top, in the
  kit's fast and normal durations, at once under reduced motion; on a computer it rests at 0.8 (Ghost.md's
  `DockShrink`, the same `app-ring` rings). Your own level is read from a connection holding only your microphone, so
  your face ripples alone in a call too, from the media source's level or, where only that is kept, its energy over
  time. A call's faces are 52 (the floating one 64) on a computer, 40 and 56 on a phone.
- **Usernames, friends by username, and voice and video channels** (0.7.20; relay deployed 2026-11-15 01:51 UTC;
  deployed; Matt, 2026-11-14: "work on the friend system so we can create a profile and username under "me" ...
  always open voice channels that you can jump in and out at any time and you can see who's connected and also
  toggle video on and off, also allow for group chat video and voice calls ... with the option to call the group ...
  please make sure we stream at lossless quality").
  - **Profile** (Settings › Me › Profile, `lib/ui/profile.dart`): a username claimed on the relay's directory
    (`claim`/`whois`/`release` in relay/handles.dart, kept as hashes with the install's key), and a name and a line
    that go to friends only.
  - **Friends by username** (`lib/friends/buddies.dart`, android `Buddies.kt`): a request goes in the clear as a
    greeting carrying the asker's key, checked against the name the hub says sent it; yes, no, end and profile
    changes go sealed. The phone makes each pair's sealing key, so the routes reach them like anyone encrypted.
  - **Voice channels** (`lib/voice`, `lib/ui/voice_screen.dart`, a Voice ring in the pill): every group has one, and
    you can make your own and share it with friends. Who is in each shows without joining (the hub's new `look`).
    Hop in and out any time; mute, deafen, video on and off. WebRTC (`flutter_webrtc` 1.6.3), each to each, signalling
    sealed with the channel's key through the hub's rooms. Opus at 510 kb/s stereo 48 kHz with no DTX, noise
    suppression and gain control off; video up to 1080p and 12 Mb/s, holding resolution.
  - **Call the group** (a group's conversation header): rings every member; their app shows the call with Join.
  - **Sorting by what they last sent**: a conversation from an unknown number is sorted by its newest incoming words
    (android Store `heard`), so a pitch you answered is still a pitch ("Health insurance sales people are not getting
    caught by the sales filter"); Sales also takes insulation, gutter service, HVAC and "free ... quote".
  - Not yet: a TURN server (calls between two phones on strict carrier networks may not connect with STUN alone),
    ringing a closed app, voice on the Mac beyond channels made there, messages between username friends.
- **Cleaner, two more kinds, and a calmer frame** (0.7.19; Matt, 2026-11-14).
  - **Cleaner** (`cleaner.dart`, on): "add a "Cleaner" plugin that allows us to bulk delete messages by category and
    shows deletion progress in real time". The brush in the list's header opens a sheet of the list's groups (Codes,
    Spam, each kind, Personal & other) with their counts; nothing is ticked to begin with. Delete asks again, then
    deletes one conversation at a time with a moving bar, "Deleting 3 of 10", and a Stop that leaves the rest. The
    list's host can now `present` a page, `deleteThread` and `reload`; `ListPlace.groups` carries the groups.
  - **Each plugin's page has its switch at the top** ("Plugins should be able to be toggled on and off from the top
    of each plugin setting page"). Its row in Settings stays while it is off, saying Off, and its page then holds the
    switch alone.
  - **The list's toggle is words alone**, and a tab counts only its unread conversations, nothing where all are read
    ("remove the icons from messages and codes and the badge count for codes that are already read").
  - **Your day is not shipped** for now ("remove the plugin that gives you the digest for now"); `day.dart` stays.
  - **Notifications & receipts** (shown) and **Likely scams** (hidden), from a second sample of the phone ("there is
    still a lot of messages that are unsorted that are spam or confirmation based things that land in personal
    messages"): unsubscribed and opt-in confirmations, receipts, surveys, sign-in and security alerts, balances and
    documents; wrong-number openers, single strangers, job offers out of nowhere. Sales takes health plans, loans,
    PR, websites and brands' pushes; Debt takes debt relief. Of 283 unknown conversations, those left in Personal went
    from 113 to 25, nearly all people.
  - **The update card is at the top of the list**, above its title ("move the update banner on desktop and mobile to
    show at the top of the sidebar above where it says messages"), not over every page.
  - **Beside a pane the pill floats over the list**, the list is 320 to 380 wide, and **Mark all read is at the end
    of the title row** ("there is a reserved spot for the navbar instead of the nav floating over the left sidebar
    ... make the mark all read aligned to the right of the messages title row").
- **Personal & other in the filter** (0.7.18; Matt, 2026-11-14: "when only selecting political
  messages I still see personal messages"). The filter's menu has a row for every conversation no kind has
  (`filter_other`, `ListPlugins.othersShown`), so ticking one kind alone shows that kind alone; All ticks it too.
  Before, a conversation of no kind was always in Messages whatever was ticked. Food delivery (a kind), the
  filter's count in the accent colour and the Messages icon on the toggle came out in 0.7.17.
- **Six more plugins** (0.7.17; Matt, 2026-11-14: "let's add all of the additional ones to a plugins,
  some can be grouped into the same plugin I also want smart embeds added to expand spotify links, youtube, etc").
  Each has its switch in Settings › Plugins.
  - **Link previews** (`embeds.dart`, on): a card under a text with a link. YouTube, YouTube Music, Spotify,
    SoundCloud, Vimeo, TikTok, X and Reddit through their oEmbed addresses; Apple Music and, if "Other sites" is
    on, any page through its Open Graph tags. Logos from Simple Icons (`embed_marks.g.dart`).
  - **Quick actions** (`actions.dart`, on): chips under a received text for a time ("Today 7 PM" → a calendar
    event), an address (→ the map), a tracking number and a phone number.
  - **Replies** (`replies.dart`, on): suggested replies above the composer when the last text asks something, a
    "Needs a reply" section, and Remind me (in an hour, tonight, tomorrow) in a message's menu and for a promise
    you made ("I'll call you later"); android `Reminders.kt`.
  - **Your day** (`day.dart`, not shipped since 0.7.19): a card at the top of the list: greeting, date, and what needs a reply, deliveries,
    reminders and appointments; × puts it away until something changes.
  - **Quiet hours** (`quiet.dart`, off): sales, political and reminder texts arrive silently; optionally everything
    from 10 PM to 7 AM, contacts' urgent words still sounding (android `Notifier.quietNow`).
  - **Unknown numbers** (`strangers.dart`, on): above the composer of a conversation with a number not in
    contacts, a guess (likely spam, a business, a person) with Save, Block and Not now.
- **Summaries of unread conversations** (0.7.16; `lib/summaries.dart`, android `Summaries.kt`; Matt, 2026-11-14:
  "Use a local AI to summarize unread message conversations like apple does"). Several unread texts in a row (since
  you last wrote), or one long one, are summed up in a line in the list, marked with a sparkle, in place of the last
  words; reading the conversation puts them back. Made on the phone by Android's own model (Gemini Nano, kept by
  AICore) through ML Kit's GenAI Summarization API (`com.google.mlkit:genai-summarization` 1.0.0-beta1, conversation
  in, one bullet out, English); nothing leaves the phone. Where the model can be had and is not here, AICore is asked
  for it; a phone without it, or a computer, shows the texts as before. A summary is made once for a conversation's
  newest text (kept as `summary_<thread>`). Settings › Messages › Summaries turns it off and says where the model
  stands.
- **Kinds of text and the list's filter** (0.7.16; `lib/plugins/kinds.dart`, `FilterButton` in
  `lib/plugins/ui.dart`; Matt, 2026-11-14: "I'd like to have tabs for messages with a intelligent spam filter, debt
  collectors, political messages, payment reminders, tracking information, etc ... I'm thinking a filter dropdown
  where showing spam, political messages, and debt collectors are filtered out by default", and "also add in
  blocking of door to door sales and other sales messages like tree trimming, gutter cleaning, buying the house,
  etc"). Texts from numbers that are not contacts are sorted on the phone into kinds: Debt collectors, Political,
  Sales & solicitors and Spam (hidden from Messages as the app ships), Payment reminders, Deliveries & tracking and
  Appointments (shown). A kind is a filter, not a tab (`ListSection.filter`, `hidden`): a round funnel button
  beside Mark all read, wearing how many it hides, opens a small menu to tick each kind shown or hidden (kept as
  `filter_<id>`; All at the top ticks every kind), each with its icon; "N hidden · Show" at the list's foot shows what
  is hidden.
  Each kind is a few patterns, said in Settings › Kinds of text: one strong sign or two weaker ones. Contacts and
  your own words are never sorted; a shown kind leaves a text that looks like spam to Spam, so a fake delivery fee
  is not shown as a delivery. "Not political" (and the like) on a conversation puts it back in Messages for good.
  The Spam filter is on from the start now, its section one of the kinds rather than a tab.
- **The bubble colour is the app's accent** (0.7.15; `lib/accent.dart`; Matt, 2026-11-14: "make the bubble
  color the accent color for the app so the send button, segmented toggles, etc all get the same color as the
  bubbles if set globally and only settings inside a chat soley change the bubble color"). Two app tokens,
  `--app-accent` and `--app-on-accent` (the page's ink and paper by default, in assets/css/app.css), are worn by
  Send (a filled `IconTap`), a toggle's chosen tab (`--glacier-segment-thumb`), a switch that is on and the kit's
  solid accent (`--glacier-accent-solid`), and the page shown in the navigation pill. `AccentSheets` keeps the
  stylesheets as read and parses them again with a rule setting the two tokens to the bubble colour chosen
  everywhere, per theme; a colour that would not be seen on a theme's page (white, silver on the light page) leaves
  that page's accent the ink. A conversation's own colour (`bubble_<thread>`) is its bubbles' alone.
- **"Tell friends I'm here" turns itself on** (0.7.16; `lib/me/me.dart`; Matt, 2026-11-14: "once an account is
  linked or the phone number verified, automatically tick tell friends I'm here"): when an account is newly linked
  or the number verified, unless the person switched it off themselves (`me_listed_chosen`).
- **One Settings, on the phone and the Mac** (0.7.10; `lib/ui/settings.dart`, `lib/ui/shell.dart`,
  `lib/desktop/ui/desk_settings.dart`; Matt, 2026-11-14: "update the desktop app to have a full features settings
  page like the ghost markdown app with the plugins and all being able to make their own setting sections instead
  of the one small settings panel we have now", "desktop and mobile should also share the same settings pages",
  "when the settings is open on desktop replace the normal sidebar so it's only a two pane layout not a three
  pane"). The Mac's one small panel is gone: a computer has the phone's Settings and its pages.
  - **Where it opens.** Settings' list of sections (`SettingsScreen`) takes the list's place in the frame, and the
    page of the section chosen (`SettingsSectionScreen`) is the pane's. In a wide window (the Mac, a folding phone
    opened out) that is two panes: sections where the conversations were, with the bar still at their foot, and the
    chosen section's page beside them, the first one open from the start and its row marked. On a phone the list
    is a page over the conversations with its own way back and no bar, and a section's page slides over it, as
    before. The Messages ring, or anything that opens a conversation, a new chat or the contacts, puts Settings
    away. The pages of Settings that are open share one `SettingsModel` (`SettingsModel.take` / `give`).
  - **Which sections.** A section says which kind of device it is for (`SettingsSection.where`: everywhere, the
    phone, a computer) and may say when it is there at all (`when`). Receipts, Notifications, Your number, Android,
    Ghost Keyboard, Computers, Network, Updates, Developer and About are the phone's; a computer leaves the key and
    finding people (Encryption) to the phone and says so.
  - **Sections from outside** (`SettingsSources.add(source, first:, watch:)`): whatever has something to set hands
    Settings its sections, before or after the app's own, and Settings is drawn again when what they are read from
    changes. The Mac's frame hands over its four while a phone is paired (`DeskSettings`): **Your phone** (the
    pairing, how the two connect, the phone's address by hand, unpairing), **Kept on this Mac** (how many
    conversations and how much space, and clearing them), **Updates** (this version, look for one, restart to
    update) and **About**.
  - **A plugin's own section** (`GhostPlugin.settingsPage`, a `PluginSettingsPage`: its colour, a line of
    introduction, a summary for its row). A plugin that asks for one has a row under Plugins while it is on, opening
    a page of its own settings (`PluginSetting`s, then what it puts in `Slots.settings`); Settings › Plugins keeps
    its switch and leaves its settings there. One that does not ask keeps its card on Settings › Plugins. Codes and
    Spam filter each have one.
- **Plugins** (0.7.4; `lib/plugins/`; Matt, 2026-11-14: "prime the whole app to have plugin support for
  placing UI elements and doing things like filtering out spam messages separating OTPs into their own section and
  more"). A plugin is a name, a line saying what it does and a switch in Settings › Plugins, kept with the person's
  other choices (`plugin_<id>`). Switched off it adds nothing and is never asked. Switched on it adds through four
  kinds of extension point (`plugin.dart` is the contract, `registry.dart` is what the screens ask):
  - **Classifiers** say which tags a conversation or a message deserves (`code`, `spam`) from who sent it, what it
    says and whether the sender is a contact. The list has each conversation classified once and keeps the answer
    until its last words change (`tag_store.dart`): the first 64 handed over, which is the first screen, at once;
    after those for no longer than two milliseconds at a time, the rest between frames. So the list opens as fast
    with thousands of conversations as it does with no plugin.
  - **Sections** of the list: a chip under the search field, beside "Messages", for each section that has
    conversations in it, and a list of its own when the chip is chosen, the newest first. A section takes the
    conversations it wants out of the main list and says how its rows look in words the list draws: a value drawn
    large, a quiet line, a button at the row's end, a word to press, what a tap does. A search from the main list
    looks through the sections too. A conversation can be filed by hand, in a section or in the main list, and
    stays there whatever the classifiers say of it afterwards (`plugins_filed`).
  - **Slots** are named places on the screens for a plugin's buttons, menu lines or widgets (`Slots`). Drawn now:
    the list's header, between the search field and the list, a conversation's long-press menu in the list, and a
    plugin's own card on Settings › Plugins, and in a conversation (0.7.17): its header, a message's menu, under a
    message (`Slots.underMessage`) and above the composer (`Slots.aboveComposer`), through `ConversationPlugins`
    and `PluginThread` (which lets a plugin write into the composer).
  - **Rules for a message that has just come**: mute the conversation, mark it as read, file it in a section. They
    are decided in Dart, by the list, for each unread conversation as it is first seen: while the app is open, and
    catching up the next time it is opened. Android's side has posted the notification by then (`Messaging.kt`
    calls `Notifier.incoming` as the text is stored), so the text that lands a conversation in a rule still
    notifies. For a rule to hold while the app is closed the receiver would have to decide before it notifies:
    the classifier it needs written in Kotlin (the code finder already is, `Notifier.otp`) or run in a Dart
    isolate the receiver starts, reading the same choices (they are in the `ui` preferences, under `plugin…`).

  The plugins the app ships with are compiled in (`shippedPlugins` in `registry.dart`): Codes and the Spam filter, below. A screen asks the
  registry what there is for a place and draws it; a plugin is handed facts and a host to ask things of (say
  something, copy, open a conversation, mark it read, file it), never a screen. One that throws is left out and
  said in Settings › Developer's log. All of the contract but the widget slots is data in and data out
  (`MessageFacts.toJson` is what a plugin is shown), so a plugin from outside the app could meet it. What that
  would still need: something to run it (an interpreter for a script; a package would have to be built in, since a
  release build cannot load Dart that was not compiled with it), a way to install and list one, a time limit on a
  classifier, a say for the person in what a plugin that reads their messages may ask of the host (none of the
  host's verbs reaches the network, and that is the whole of what a plugin can do), and a way to describe widgets
  in words for the widget slots. Tests: `test/plugins_test.dart` (the contract, the registry, the tags; 5,000
  conversations are handed over in about 4 ms and sorted into sections in about 3) and
  `test/plugins_list_test.dart` (the list and Settings › Plugins, with a plugin made up for the tests).
- **How large a video came** (0.7.10; `lib/ui/video.dart`; Matt, 2026-11-14: "the videos sent from iphone are
  extremely low quality", and, asked whether the app should say so, "Yes, add it"). Under a video in a conversation
  is its own size and its file's ("320 × 240 · 913 KB"), and, where it came from someone else under 480 pixels the
  short way, "Shrunk by the sender's phone to send as a picture message." The app does nothing to a video: it is
  fetched by Android's own picture-message service with the carrier's settings, kept as it came and played from
  there (no code here re-encodes one). A phone that sends a video as a picture message shrinks it to what its
  carrier takes, about a megabyte, and what was taken out cannot be put back by the phone it reaches. The phone
  reads the size from the video itself (`Video.preview`: `videoWidth`, `videoHeight`, `bytes`), the Mac from the
  copy it fetched (`DeskVideo.preview`).
- **Who a code is from** (0.7.9; `lib/plugins/companies.dart`; Matt, 2026-11-14: "have the codes section try
  to parse the company that's sending the code and show their company logo as the code profile picture like
  coinbase discover etc"). A code comes from a short number that says nothing; the company is in its words. A row
  in Codes is called by it, and wears its face: for one of about 120 companies the app knows by name (or by another
  it goes by, "BofA", "Amex", or by its web address in the text), a disc of the company's colour with its mark on
  it; for any other, the name its text gives itself ("Acme: your code is…", "Your Acme verification code is…") and
  that name's letters; for a text that names nobody, its number as before. All of it is read on the phone from the
  text alone, and nothing is looked up for a name out of a text. **The marks** are built into the app from an open
  pack of brand icons (Matt, asked where logos should come from: "download in the app look for brand icon packs
  that might exist"): Simple Icons, CC0 1.0, each one path, made into `lib/plugins/company_marks.g.dart` by
  `tool/company_marks.py` (its head says how to fetch the pack and run it). 86 companies have one. The 36 the pack
  does not have (most banks and shops) get their letter on their colour. 14 of the 86 the pack has since taken out
  at their owners' wish and still carries for old uses (Amazon, Microsoft, LinkedIn, Walmart, Slack, Yahoo,
  Nintendo, Hulu, Grubhub, Adobe, Salesforce, OpenAI, Twilio, DocuSign): they were first left as letters, and are
  drawn as the pack last had them since Matt, asked, said "Use older logos" (`OLDER` in the tool). The marks are
  trademarks of their owners, drawn only to say who a text is from. A switch in
  the plugin's settings, "Show who a code is from". Tests: `test/plugin_companies_test.dart`. Pictures:
  `test/shots/12-plugins-codes-*`, and every face in `12-plugins-company-faces-*`. Found on the way and not
  changed: "G-482913 is your Google verification code" is not taken for a code at all (the "-" before its digits),
  by `signInCode` and `Notifier.otp` alike.
- **Codes** (0.7.4; `lib/plugins/codes.dart`; Matt, 2026-11-14: "separating OTPs into their own section").
  The first plugin, on until it is switched off in Settings › Plugins. A conversation whose newest text is a sign-in
  code, from one number that is not in the phone's contacts, leaves the main list for a Codes section: a chip under
  the search field that counts them, and in it the newest first, each code drawn large over the words it came in.
  A tap on the row, or the button at its end, copies the code and marks the conversation as read (its own setting,
  "Mark as read when copied"). Its long press opens the conversation, copies, or keeps it in Messages, which
  sticks. A contact's "the door code is 4417" stays in the main list, where its long press has "Copy 4417" and
  "Move to Codes". What reads as a code is what the notification's Copy button says is one: `signInCode` is
  `Notifier.otp` written again in Dart, and the two are held to the same examples (`test/code_vectors.json`, read
  by `test/plugin_codes_test.dart` and by `CodesTest.kt`), so they cannot drift apart. In both, the word that
  speaks of a code is now a word of its own: "pin" is in "shipping", "shopping" and "opinion", so "Your order
  482913 is shipping today" was taken for a code, which a Copy button could bear and a section cannot. The list knows a
  conversation by its last words: it is in Codes while its newest text is a code and back in the main list once a
  later text is not, and since the list does not know whose the last words are, a code the person texts to a
  number themselves is sorted too. The plugin also has "Copy 482913" for a message's menu inside a conversation,
  which waits for that slot to be drawn. Pictures: `test/shots/12-plugins-*`.
- **Groups of friends** (0.7.6; [docs/groups.md](groups.md); Matt, 2026-11-14: "expand on the ability
  to create, name and manage groups like telegram"). New group, in the address book, makes one out of friends: a
  name every member sees, members, and admins, who rename it, add a friend, take someone out and make another
  admin; anyone can leave. What is written in it goes to each member over the internet by the app's routes, sealed,
  never as an MMS, and its conversation is its own, with lines for what happened to the group ("Ann added Dan").
  Members need not be friends of each other: the group gives each the others' keys. Words only for now, and written
  from the phone. Like friends, nothing of it is offered until a relay server answers.
- **A group's name** (0.7.5; Matt, 2026-11-14: "expand on the ability to create, name and manage groups like
  telegram"). A group conversation's settings have a Group name field; named, the group goes by it in the list, in
  its conversation and on a paired computer, and emptied it goes by its people's first names again. The name is the
  phone's own (`Store.threadName`, sixty letters at most): a group text has nowhere to carry one, so the others in
  the group do not see it. A computer sets it through the phone (`threadName` over the link). This is a group text's name; a group of
  friends (above) has one every member sees.
- **Me, and friends joining** (0.7.9; [docs/me.md](me.md); Matt, 2026-11-14: "Add a 'me' section to settings
  and allow linking popular social like telegram, discord, x, etc to be notified when one of your friends or
  followers joins ghost messaging"). Settings › Me links an account by proving it is yours: Discord, X and Telegram
  by signing in there, Bluesky, Mastodon and GitHub by a code in the public profile. Settings › Friends joining is a
  watch list of handles (typed or pasted; brought in from who you follow on Bluesky, Mastodon and GitHub, the three
  that publish it) and who of them is here, with the number of new ones on the Settings ring. Someone is told only
  of a person who linked that account AND switched on "Tell friends I'm here". The relay server's keeper of handles
  (`relay/lib/handles.dart`) holds hashes of handles, never a handle or a name, and is told nothing until an
  account is linked, a handle added or the page opened. Each network's sign-in is off until its app is registered
  and its values put on the box (docs/me.md says how); the three proved by code need nothing. Held by
  `relay/test/handles_test.dart` and `test/me_test.dart` (two installs through the real relay) with the networks
  stood in for. **On the server since 2026-11-14 18:04 UTC** (the relay put up again with the keeper of handles in
  it, and ghost-sms.com's block passing `/link/*` to it; Matt: "deploy both yes"), so the three proved by a code
  can be tried; Discord's, X's and Telegram's sign-ins are still off, their apps not registered. **Not run against
  a real network yet.**
- **Your number, verified by a text** (0.7.12; on the Mac, through the phone, 0.7.13; [docs/me.md](me.md); Matt, 2026-11-14: "I'd
  like to use a third party service that allows us to send the text code to a number to verify so it can't be
  spoofed"). Settings › Me › Number says Not verified and opens a page that has a code texted to the number; the
  page reads the code out of the text as it arrives and the row then says Verified. The code is made, sent and
  checked by a texting service (Twilio Verify, `relay/lib/texts.dart`), so a phone cannot simply claim a number.
  Only the install a code was sent for may try it; three codes an hour and six a day for an install and for a
  number, 200 texts a day in all, North American numbers only unless the server is told otherwise. A verified
  number is told to nobody, and nothing watches for one: today it is a mark on your own page. The relay keeps the
  number's hash, which unlike a handle's can be worked back, so the server is to be thought of as knowing it.
  **Off until** a Twilio account and Verify service exist, their three values are on the box, and the relay is put
  up again (docs/me.md says how; all Matt's to do or say). Held by `relay/test/handles_test.dart` (nine, the
  service stood in for), `test/me_test.dart` (through the real relay) and `test/number_screen_test.dart` (which
  text the page reads a code from). On the Mac the number is the phone's and is verified through the phone (Matt:
  "on desktop the phone number reads as unknown and is not proxying the verification process"; `DartAsk.kt`,
  `Me.followPhone`/`forComputer`; the phone's app must be open). **Verified against the real service on
  2026-11-14** (relay deployed with the values at 20:06 UTC; a code to Matt's number checked at 20:14).
- **Friends** (0.7.5; [docs/friends.md](friends.md); Matt, 2026-11-14: "Add a friend system that allows
  users to talk without using SMS or MMS but still validate accounts by telephone numbers for now. If both users
  chatting are on ghost messenger show an 'add friend' button"). Where both phones have the app the conversation
  offers Add friend; once each has said yes, words between the two go over the internet by the app's routes, sealed,
  and are kept in the same conversation with a globe beside them. A friend is someone keys were exchanged with by
  text, which is what proves the number: no account. With no relay server reached they go as the encrypted texts
  they would have been; a friend whose app is closed is sent one silent data text and their phone says a message
  is waiting. Nothing of it is offered until a relay server answers; ours does, at wss://ghost-sms.com/hub, since
  2026-11-14.
- **Spam filter** (0.7.4; `lib/plugins/spam.dart`; Matt, 2026-11-14: "filtering out spam messages"). The
  second plugin, off until it is switched on in Settings › Plugins: a filter that takes messages out of the list is
  chosen, not given. On, a conversation whose newest text looks like spam, with nobody in it a contact, leaves the
  main list for a Spam section beside Codes. Its row says which signs the text showed ("Looks like spam: a link,
  prize wording") and has "Not spam", which puts it back in the main list for good, whatever comes in it later. A
  conversation the rules missed is moved there by hand from its long press ("Move to Spam"), unless it is a
  contact's. The rules are six signs, each a line in the plugin's card in Settings: a link, sent from an email
  address, prize wording, pressure to act, a money offer, a delivery problem. A text is spam when it shows two of
  them, or three where it also holds a sign-in code (which often comes with a link and "if this wasn't you"); a
  contact's text is never looked at. They are a list of plain values (`spamRules`: a pattern for the words, or for
  the address a text came from), so another list can stand in for them (`SpamPlugin(rules: …)`). All of it is
  decided on the phone: nothing is sent anywhere, deleted or blocked. "Mute conversations in Spam" (on) mutes a
  conversation in Spam as its text is seen, so what comes in it next arrives without a notification; "Not spam", or
  switching the filter off, takes that mute off again, and a mute the person made is left alone. The text that
  first puts a conversation in Spam has already notified (Plugins, above, says what Android's side would have to
  do). A text that is both a sign-in code and spam is in Codes, which is asked first. Tests:
  `test/plugin_spam_test.dart`. Pictures: `test/shots/12-plugins-spam-*`, `12-plugins-settings-spam-*`.
- **On a Mac** (built 2026-11-13, not released; [docs/desktop.md](desktop.md); Matt: "a companion desktop app
  that can proxy messages encrypted from my phone to my desktop and then send back to the phone to send again", and
  "I'd like to support both a relay server and local networking, it should attempt to use local networking by
  default and show the option for both in the setup wizard"). Uplink for the Mac shows the phone's
  conversations beside the one open, shows a new text as it arrives, and sends what is typed there through the
  phone, which stays the only thing that texts. The two are paired by a QR code the Mac shows: the phone's own
  camera opens it in the app, which asks first ("Pair with Matt's MacBook Pro?"), or Settings › Computers › Pair a
  computer scans it or takes it pasted; both then show six digits to compare. Everything
  between them is sealed with a key made in the pairing (the phone-to-phone encryption's construction, with a key
  for each connection and a counter on every frame, so nothing can be replayed). They reach each other on the local
  network (the phone announces itself, the Mac finds it) or through a relay that passes the sealed frames and keeps
  none: both wizards offer local network then relay (the default), local only, or relay only. Settings › Computers
  lists the paired computers, how each is connected, and Unpair; the Mac unpairs too. While a computer is paired the
  phone shows a quiet permanent notification, which is what lets Android keep it reachable. What is typed on the Mac
  while the phone cannot be reached waits there, "Waiting for your phone". The Mac keeps what it has read (the
  list and each conversation's messages) sealed on its disk with a key made from the pairing's, answers the
  screens from that at once, and fetches only what is new from the phone behind them (0.7.10; docs/desktop.md,
  "What the Mac keeps"; Matt, 2026-11-14: "cache messages on the desktop app so that we don't need to fetch them
  all from the phone every time, just fetching updates in the background"). A
  computer can read, send text, mark read, pin, mute and archive; it cannot delete, block, change encryption or
  send pictures. The relay is on our server since 2026-11-14 (`wss://ghost-sms.com/relay`).
- **Settings** (0.4.0; Matt, 2026-11-13: "make the settings page more like ghost kbd where it's nested sections and
  expand on the settings available"): a home of sections in groups with a search over every setting, each opening its
  own page, as Ghost Keyboard's does (`lib/ui/settings.dart` is the frame, `lib/ui/settings_panes.dart` the pages).
  Appearance (theme, your bubbles, text size), Chat background, Emoji (the sets, large emoji), Effects; Messages
  (Enter sends, attach reactions to messages), Receipts (delivery reports, read receipts, the ticks explained),
  Notifications (Android's permission, message previews, the copy-code button, sound and vibration); Encryption (what
  it is, the people, this phone's key, a new key), Blocked numbers (tap to unblock), Archived; Your number, Android
  (default SMS app, contacts, phone number), Ghost Keyboard (0.5.0); Updates, About. Settings › Updates says "ghost-sms.com isn't serving
  updates yet" where the site has no certificate, no such name, nothing answering or no release, and "This phone is
  offline" where that is why, in place of Java's own error.

Not yet: RCS and iMessage (no API exists for apps other than Google's and Apple's own, so no typing indicators and
no read receipts for plain texts), sending video or audio, scheduled messages, search inside messages, dual-SIM
choice (the phone's default SMS SIM is used), and a backup.

## How it is built

| Part | Where | What |
| --- | --- | --- |
| The screens | `lib/` | Flutter, drawn with Glacier (`packages/glacier`, copied from Ghost Keyboard's copy of Ghost.md's kit: `packages/glacier/VENDORED.md`), Ghost.md's stylesheets (`assets/css`), Ghost Keyboard's settings kit (`lib/kit`) and Lucide icons drawn as Ghost.md draws them (`lib/art`). |
| The bridge | `lib/sms.dart` and `MainActivity.kt` | `ghost_messaging/sms` (calls) and `ghost_messaging/events` (a conversation changed; a notification asked for one). |
| The messages | `Store.kt` | Android's SMS/MMS provider: conversations, messages, parts, contacts, and writing what arrives or is sent. |
| Sending and receiving | `Messaging.kt` | `SmsManager` for SMS and MMS, and the receivers Android requires of a default SMS app (`SMS_DELIVER`, `WAP_PUSH_DELIVER`). |
| MMS bytes | `Pdu.kt` | The MMS wire format, reading m-notification-ind and m-retrieve-conf and writing m-send-req and m-notifyresp-ind. Android does the radio and the carrier's HTTP but leaves the bytes to the app. Tests: `android/app/src/test/.../PduTest.kt`. |
| Notifications | `Notifier.kt` | Notifications with Reply and Mark as read, the "respond via message" service, and the file provider Android's MMS service reads and writes through. |
| Paired computers, on the phone | `Desk.kt`, `DeskService.kt`, `DeskSession.kt`, `DeskCrypto.kt`, `WsClient.kt`, `ScanActivity.kt` | Who is paired and each one's key (under an Android Keystore key), the foreground service that listens on the local network (NSD) and dials the relay, one connection as the phone answers it, the sealing, a WebSocket client written out, and the QR scanner (Camera2 and ZXing). Tests: `DeskCryptoTest`, `DeskSessionTest`, `WsClientTest`, `ScanTest`. |
| The Mac app | `macos/`, `lib/desktop/` | The same Flutter project with a macOS runner: `lib/main.dart` goes to `lib/desktop/main.dart` on a computer. `link/` is the sealing (pointycastle), a connection, the relay's socket and `PhoneLink` (pairing, local first, the relay when it fails); `remote.dart` answers the phone's screens' calls from the phone; `ui/` is the wizard, the two panes and Settings; `macos/Runner/DeskChannels.swift` is Bonjour, the Keychain and the Mac's name. |
| Plugins | `lib/plugins/` | The contract (`plugin.dart`), the registry and the plugins the app ships with (`registry.dart`), the conversations' tags (`tag_store.dart`), what the list of conversations keeps of them (`list.dart`), what a conversation would ask (`conversation.dart`), what is drawn of them (`ui.dart`), their settings for the Marketplace's pages and Settings' search (`settings.dart`), the plugins themselves (`codes.dart`, `kinds.dart`, `spam.dart`, `embeds.dart`, `actions.dart`, `replies.dart`, `day.dart`, `quiet.dart`, `strangers.dart`), and plugins from other developers (`pack/`: the `ghost-plugin/1` format, its phrases, running a pack, review and what is installed). |
| The Marketplace | `lib/ui/market/`, `lib/market/`, `relay/lib/market.dart` | The ring's place on the rail and its sections: Discover, Added, Updates, Submit a plugin, My submissions, Plugins in development and the review queue (`lib/ui/market`); the client and the catalog's checked state (`lib/market`); the store and its review on the relay (`relay/lib/market.dart`, `market_pack.dart`, `market_store.dart`). `docs/marketplace.md` says how it fits together. |
| The docs | `docs-src/`, `tool/build-docs.mjs` | gogho.st/docs: each page's body, with mock tags drawn as the app draws itself, built into `site/docs` with the example plugins (`examples/plugins`) copied in (`node tool/build-docs.mjs`; `--check` fails where they differ), and shipped by `tool/deploy-site.mjs`. |
| The relay | `relay/` | A WebSocket server in Dart's own library alone (`relay/README.md`). Not on a server. |

## Building

```sh
flutter pub get
flutter build apk --release --target-platform android-arm64   # build/app/outputs/flutter-apk/app-release.apk
flutter test                                                  # reactions, edits, effects, emoji sets, settings and backgrounds; builds every screen;
                                                              # the Mac's sealing and its link to a stand-in phone through the real relay
flutter test --update-goldens test/screens_test.dart          # every screen, light and dark, written to test/shots/
flutter test --update-goldens test/desk_screens_test.dart     # the Mac's screens, written to test/shots/mac-*
cd android && ./gradlew :app:testDebugUnitTest                # the MMS encoder and decoder, the encryption, a background as a text, the codes offered,
                                                              # the sealing with a computer, a computer's connection, the WebSocket client, a QR code read
flutter build macos                                           # the Mac app: build/macos/Build/Products/Release/Uplink.app
(cd relay && dart test && dart run bin/relay.dart)            # the relay: its tests, then ws://127.0.0.1:8787
flutter test integration_test/desk_live_test.dart -d macos    # the real Mac app against the phone app on an emulator (the file says how)
```

`flutter build apk` builds the phone app exactly as before: the Mac app is the same project's other platform, and
nothing of it is in the APK but the Settings page and the phone's half (`Desk*.kt`).

The emoji sets' picture (`test/shots/7-emoji-sets.png`) is compared on Linux only: a Mac's test engine draws fonts
with Core Text, which leaves Twemoji's row blank, where Linux's and Android's draw it with FreeType.

## Releasing (ghost-sms.com)

Each release publishes the source by itself: tool/release.mjs, release-mac.mjs and release-windows.mjs end by running
`node tool/publish-source.mjs` (github.com/InfamousVague/ghost-messaging, one commit a release, messaging/ as
committed at HEAD; and the sidecar's own repository where it changed). `--no-source` skips it; a failure there is said
and leaves the release live. A release that carries the Google Messages sidecar must have its source public.
Since 2026-11-27 the same snapshot also goes to github.com/Satellite-im/Uplink's `main`, the app's home under its new
name (Matt, asked whether every release should update it: "Yes, every release"), last of the three. That
repository's `main` is its default branch; the Rust app it held before is on `dev` and in the 1.0.x tags.

**The runners are to be that repository's** (Matt, asked "Move the Windows, Linux and relay builds onto
Satellite-im/Uplink?": "Yes, move them"), and everything for it is in place but the two things that are Matt's.
The build workflows are the app's own files now, `.github/workflows/windows.yml`, `linux.yml`, `relay.yml`,
`p2p-core.yml` and `windows-video-check.yml` in this folder, which is that repository's root, so they are published
with the source and build what was published beside them. `tool/release-linux.mjs` and `tool/release-windows.mjs`
can build there (`--on uplink`; `tool/lib/runners.mjs`): they bring that repository's `main` up to the release
(`tool/publish-source.mjs`), ask for the build, and refuse one that was of any other commit.

What holds it, as of 2026-11-27:
1. **Satellite-im's GitHub account is locked for billing.** The first time the workflows were asked to run there,
   every job ended before it began: "The job was not started because your account is locked due to a billing
   issue". Nothing runs there until the organization's owner settles it. So `RUNS_IN` in `tool/lib/runners.mjs` is
   still `'glyph'`: a release builds Windows and Linux where it always did (the developing repository's
   `messaging-windows.yml` and `messaging-linux.yml`, at its `main`, into which the release is merged first). Once
   the account is settled, a trial of each (`gh workflow run linux.yml --repo Satellite-im/Uplink --ref main -f
   version=<v> -f build=<n>`), and when they pass `RUNS_IN` becomes `'uplink'`; the two old workflows are deleted
   after a release of each has gone out from the new place.
2. **The signing secrets are not there.** Windows' installer is signed with `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`,
   `AZURE_CLIENT_SECRET`, `AZURE_SIGNING_ENDPOINT`, `AZURE_SIGNING_ACCOUNT` and `AZURE_SIGNING_PROFILE`, which the
   developing repository has and Satellite-im/Uplink has not been given (a secret's value cannot be read back out of
   GitHub, so they are Matt's to add). Whatever `RUNS_IN` says, the Windows script builds there only when they are
   present, and says which it chose: an unsigned installer never takes a signed one's place.

The relay's workflow runs in both repositories the source is published to; its release in Satellite-im/Uplink is
never marked the latest, which is the app's, and its container there (`ghcr.io/satellite-im/ghost-relay`) starts
private until someone makes the package public by hand, so the docs still name `ghcr.io/infamousvague/ghost-relay`.
While the account is locked it fails there like the rest, on each release that changes the relay.

And each release is a release on GitHub there too (`node tool/release-github.mjs`, run by the same four scripts
after the source; Matt, asked whether every release should publish one: "Yes, every release"). It is tagged `v` and
the version and carries the installers the site's feeds say are out at that version, the very files the site serves
(checked against each feed's size and SHA-256), under names that say Uplink, with `SHA256SUMS.txt`. It is a draft,
seen by the repository's own people alone, until every platform is out at that version: the Mac's script makes it,
the others add to it, and the one that finds all four out publishes it as the latest. `--publish` publishes one of
fewer platforms; `--no-github` on a release script leaves the step out; run again, it adds only what is missing.

Matt, 2026-11-13: "add auto update and serve it over ghost-sms.com I'll point the domain to the same server ghost kbd
uses". Both scripts are Ghost Keyboard's, for this app, and use Ghost.md's box account (`tauri/.env`) through
Ghost.md's own `box.mjs`, so they run where that file is: on the Mac, not in a cloud session.

```sh
node tool/deploy-site.mjs --caddy   # once: site/ into /opt/ghost-sms-site, and ghost-sms.com's block in the Caddyfile
node tool/release.mjs               # each release: build, sign, check, upload to /opt/ghost-sms-release, verify it is served
node tool/deploy-site.mjs           # when site/ changes
python3 tool/app_icon.py            # every icon from art/app-icon.png, when the icon changes
```

Both ran for the first time on 2026-11-13 (one box login, 19:56:05 UTC, held for both: `--keep-connection` on each
after Ghost.md's `build/diag/hold-box.mjs`): the Caddy block went in with every other site answering as before
(backup `/etc/caddy/Caddyfile.bak-20261113-195607`), and 0.3.1 (code 6) was the first release. From a worktree of
this repository the scripts need `--glyph ~/Development/Apps/glyph`: the box's `.env` is only in the main checkout.
`www.ghost-sms.com` has no DNS record yet, so its redirect has no certificate (ghostkbd.com's www is the same).

- **The release key** is made by the first `tool/release.mjs` in `~/.config/ghostmessaging/` (back it up) and its
  certificate is pinned there; `android/app/build.gradle.kts` signs release builds with it when it is present.
- **A build made without the key** (every APK so far: they were built in a cloud session and are signed with that
  machine's debug key) can't be updated to the release, since Android wants the same certificate. Such a copy says so
  in Settings › Updates. It is uninstalled and the release installed from ghost-sms.com once; no messages are lost,
  because they are Android's. Its settings, archive, pins and drafts are the app's own and start again.
- The domain must point at the box before `--caddy`, or Caddy can't get its certificate.

## What hasn't been tried on a phone

Every version so far was built in a cloud container with no phone and no emulator (no KVM). The screens and a frame
of each effect are drawn in Flutter's test harness with made-up conversations (`test/shots/`), the MMS format, its
reports and the sign-in code finder are checked by `PduTest`, reactions, effects and emoji sets by the Dart tests, and
the manifest was checked for every component Android looks for before it offers an app as the default SMS app.
Sending, receiving, MMS download and reports through a real carrier, notifications, blocking and the updater's
install have not run on a device; nor has 0.4.0's encryption between two phones, a picture as a chat background, or
Match my wallpaper, nor 0.5.0's synced background between two phones (a picture one above all: it is an MMS), nor a
0.6.0 sticker through a carrier (it is an MMS too). Since 0.6.2 picture messages have run both ways on an emulator
against a stand-in carrier (tool/mms/), which is not a carrier: a real one may still refuse what a stand-in takes. A
voice message was recorded on an emulator (whose microphone hears nothing), kept, played back, sent again after it
failed, and thrown away on leaving the app mid-recording; it has not gone through a carrier, been heard, or been
played on another phone. The frame (`lib/ui/shell.dart`) was run on an emulator narrow and widened to a folding
phone's opened size, with Android's back and another app's "text this number"; a real fold being opened and closed
with a conversation open, and the keyboard beside the list, have not been seen. `docs/HANDOFF.md` section 3 is the
list to go through on a phone.

The Mac app and the phone's half of it were tried against each other on an emulator, by each way of connecting
([docs/desktop.md](desktop.md), "Trying it"). Not on the Fold: the two finding each other on a real network
(Bonjour and NSD), the camera reading the Mac's QR code, the Keychain in a signed build, and the phone staying
reachable through deep sleep.
