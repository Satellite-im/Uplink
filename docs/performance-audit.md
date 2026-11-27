# Performance audit (2026-11-20)

Matt, 2026-11-20: "Please audit the whole app and search for ways we can improve performance it's quite laggy on
linux". Every finding is fixed or answered, said under each. None of it has been measured on Linux yet. Read at 0.10.4 (`49d0e0a21`).

**How it was done, and what it is not.** The code was read for what makes frames slow or keeps them coming (three
sweeps: idle animations and timers; rebuild scope and lists; blocking work on the UI thread), and the top findings
were checked in the code. Two were measured with throwaway tests on a Mac. **Nothing was measured on Linux**: there
was no Linux machine to run on, so the order below is by reasoning, not by a profile. None of the findings is
Linux-only; Linux (often a weaker GPU path, sometimes software rendering) shows them first.

**First, on the Linux machine itself:** `glxinfo | grep "OpenGL renderer"`. If it says `llvmpipe`, the app is drawn
by the CPU (no GPU driver, or a VM), and everything below is a multiplier on that. The Linux runner is Flutter's
stock one (`linux/runner/my_application.cc`); the build is `flutter build linux --release` with no special flags.

## Ranked findings

### 1. Every settings write rebuilds and re-themes the whole app (proven)

**Fixed 2026-11-20** (Matt: "Yes, fix both"; `test/perf_rebuilds_test.dart`, which fails without the fixes): the
typography object is the same for the same emoji set (`ghostTypography`, `lib/main.dart`), so a choice written no
longer makes new tokens; `AppState.set` to the same value does nothing; `AppState.keep` keeps a store's bookkeeping
without telling the screens (`voice_seen`, `voice_read`, `hangout_*_m`, `circles_seen`); the computer's choices file
is written at most once in 200 ms, the newest of a burst, and the folder is closed (`chmod 700`) once a run in place
of a `chmod` started for every write (`lib/desktop/store.dart`). Still as it was: `AppScope` tells every
`AppState.of` dependent on each real change, and the other stores' keys still go through `set`.

- `AppState.set` (`lib/app_state.dart:38`) always notifies, also when the value did not change.
- The app's root listens (`lib/desktop/main.dart:320`, `lib/main.dart:195`) and rebuilds `WidgetsApp`, passing
  `typography: ghostTypography(state.emoji)`: a new object each time, with no `==`.
- `GlacierTheme` keys its tokens on that object (`packages/glacier/lib/src/tokens/theme.dart:76`), so it makes new
  root `Tokens`: every widget that reads `context.tokens` (nearly all) rebuilds, every token cache is dropped, and
  every `GlacierScope` (one per avatar) scans the sheet's 134 rules again.
- `AppScope` also tells all ~100 `AppState.of` dependents every time (`version: Object()`, `app_state.dart:122`).
- Each write also encodes the whole prefs file (111 KB on Matt's Mac), writes it with a flush, and **starts a
  `/bin/chmod` process** (`lib/desktop/store.dart:39-48`).

Measured (throwaway test): after `state.set('voice_seen', …)` the theme is a different object and its dependents
rebuild. A new root with ~15 lookups is ~1 ms and an avatar's scope ~0.13 ms (debug VM): the theme itself is cheap;
the cost is the whole tree rebuilding, laying out and painting.

What writes there while the app is just open: `voice_seen` on **every** presence "looks" event from the hub
(`lib/voice/channels.dart:228`, from `:436`), `hangout_*_m` per space message (`:974`), summaries, circles' seen
marks, kept lists, emoji recents; the text-size slider on every tick.

Fixes, small: memoise `ghostTypography` (or give `GlacierTypography` equality); `set` returns early when unchanged;
bookkeeping keys (seen/read marks) do not notify, or live outside `AppState`; debounce the prefs write; set the file's
mode once instead of spawning `chmod`.

### 2. The conversation list rebuilds whole on any network, voice or summary change, with O(N) work each time

**Fixed 2026-11-20** (Matt: "fix all the performance issues found above"; `test/perf_lists_test.dart`): a network's
shown and archived chats are made once for each change and each state of Uplink's own lists (`InboxNetwork.stamp`,
`shownChats`), and one of those lists is read from its kept form once (`localList`); Telegram marks its lists stale on
an update and makes them when next read, once, and TDLib's JSON is read in its own isolate; a chat's scam signs are
remembered; a tab's conversations are worked out once a build. Still as it was: the list is one `State` that builds
whole on any of its notifiers (a build is now cheap, but it is still a build), and Voice tells it of every change in
a call.

- `ConversationsScreen` calls `setState` on `Summaries`, `Voice`, `Circles` and every network
  (`lib/ui/conversations.dart:170-188`); the build then filters, sorts and re-parses pref strings per chat
  (`_shown`, `_of` twice, `_mixed`, `shownChats`/`localList` in `lib/inbox/inbox.dart:482,598`), runs scam regexes
  per snippet (`lib/inbox/scams.dart:106`), and each network's `chats` getter rebuilds every `InboxChat`.
- Telegram re-sorts all chats and notifies on almost every TDLib update, uncoalesced
  (`lib/inbox/telegram.dart:688`): thousands at sign-in and start. TDLib's JSON is decoded on the UI thread
  (`lib/inbox/td_json.dart:104`).

Fixes: coalesce each network's notify to one a frame; cache `chats` and the parsed lists by a change stamp; memoise
the per-chat facts; decode TDLib's JSON in its own isolate.

### 3. A conversation builds every message it holds, with regexes made per message

**Fixed 2026-11-20** (`test/jump_to_latest_test.dart`): the list is a builder, a message one keyed row made as it
nears the screen, so what the plugins find in a message's words is found for the rows on screen alone. The patterns
were left where they are: Dart keeps the patterns it has compiled, so making one again by its source is a lookup.
The Dial-Up look's transcript (`_lines`) is still built whole.

- `lib/ui/thread.dart:1091`: `ListView(reverse: true, children: items)`, not a builder: 120 messages at first, 300
  more a page, all built on every rebuild.
- Per message per rebuild: plugin fills construct ~14 `RegExp`s (`lib/plugins/actions.dart:48-130`), find links
  (`embeds.dart:246`), and more (`conversation.dart:105`).
- Rebuilt on any `AppState` change (so on finding 1), groups, sends, loads.

Fixes: `ListView.builder` over prepared rows; cache a message's fills by its key; make the regexes top-level finals.

### 4. Signal, WhatsApp and Matrix write their whole store on the UI thread after every event

**Fixed 2026-11-20** (`test/kept_writer_test.dart`): `lib/inbox/kept_writer.dart` hands what is kept to another
isolate, which makes the JSON and writes the file, a run of changes as one write (two seconds after the last, ten at
most after the first); the three stores, Telegram's kept edits and a files space's log go through it. WhatsApp knows
a message it has by an index of ids and sorts a chat only when a message comes out of order; Signal looks from the
end back. Still as it was: history is never trimmed (Signal's exists nowhere else), each store is read whole on the
main thread as the app starts, and a helper's lines are read (JSON) on the main thread one at a time.

- `lib/inbox/signal.dart:880`, `whatsapp.dart:760`, `matrix.dart:776`: `writeAsStringSync(jsonEncode(everything))`
  400 ms after each message, receipt, reaction or name; history is never trimmed, so it grows without end.
- WhatsApp's history sync is quadratic (`whatsapp.dart:366-415`: a linear dedupe and a whole-chat sort per message),
  and the one giant line is decoded on the UI thread. Signal has the same per-message `any` + `sort`.

Fixes: write asynchronously (encode in an isolate), a longer debounce, a file a chat or a cap; an id set and one sort
a batch.

### 5. After the first call, the window is redrawn every frame for ever

**Fixed 2026-11-20** (`test/perf_rebuilds_test.dart`): the beat and the call's clock run only while there is a call
(`_CallBannerState._sync`), and the dot is painted by itself (`RepaintBoundary`).

`lib/ui/voice_screen.dart:677`: the call banner's pulse (`..repeat(reverse: true)`) starts with the first call shown
and is never stopped; the banner stays mounted in the sidebar with no `RepaintBoundary`. From then on the app
asks for a frame at every refresh, call or no call. During a call it sits over a blur (`:728`), re-blurred each
frame. Fix: run it only while there is a call; a `RepaintBoundary` round it.

### 6. Pictures decoded at full size, and some decoded again on every rebuild

**Fixed 2026-11-20** (`test/picture_decode_test.dart`): `lib/kit/picture_decode.dart` gives the width to unpack a
face or a filling picture at, keeps a base64 picture's bytes so each build hands the image cache the same ones, and
reads a previewed file once. Faces, space and profile faces, circle banners, a network's message photographs, the
chat background and the files preview use it. The full-screen viewer still unpacks the whole picture (it zooms).

- Avatars and message pictures have no `cacheWidth` (`lib/ui/common.dart:764,774`, `lib/ui/inbox_ui.dart:1425`,
  `thread.dart:2113`): a 40 px face decodes the whole photo.
- Space faces `base64Decode` and decode anew each build, one a message row (`lib/ui/hangout_screen.dart:2461`,
  `profile_card.dart:514`, `circles/circle_list.dart:213`); `file_preview.dart:182` reads the file in `build`.

### 7. Signature checks inside builds (spaces and circles)

**Fixed 2026-11-20** (`test/perf_verify_test.dart`): `NetCrypto.verifyOnce` remembers the answer for the same key,
message and signature; a roster's and a circle's grants ask it.

`lib/voice/roles.dart:235` and `lib/circles/circle.dart:362-403` verify P-256 signatures in pure Dart from getters
that rows call while building (`hangout_screen.dart:1815`): several ms each, per message row, per rebuild. Fix:
remember the answer per grant.

### 8. Smaller, real

**Fixed 2026-11-20**: the search (each conversation's words folded once, `conversations.dart`); the resize
(`GlacierTheme.resizeSettle`, 120 ms on a computer; `test/perf_rebuilds_test.dart`); the polls (Bluesky, Mastodon,
Google Chat, Teams and the phone's friends tell their listeners only when the answer differs); the spinner paints by
itself. **Left, on purpose:** every face listening to presence (looked at again: the face itself is not built again,
only a dot, so there is little to win); hover building a row again (inside the kit, and it stays in the row); and
pausing when the window is hidden (Flutter stops drawing a hidden window by itself; what goes on is the networks'
asking, which notifications need).

- Every avatar listens to all presence changes (`common.dart:665`): one status change rebuilds every face.
- Search scans everything on each keystroke (`conversations.dart:530`): debounce, pre-fold once.
- Resizing the window makes a new theme every frame (`theme.dart:75` keys on the window's size): resize stutter.
- Polls that notify with nothing new: Bluesky, Mastodon, Google Chat, Teams every 20-30 s; buddies every 20 s on a
  paired computer (`friends/buddies.dart:240`). Each is a full list rebuild (finding 2).
- The desktop app never pauses when the window is hidden or unfocused: no lifecycle handling in
  `lib/desktop/main.dart`.
- Hover rebuilds the whole row (`packages/glacier/.../pressable.dart:89`): contained, minor.

## Looked at and fine

Icon paths are parsed once (`lib/art/svg_path.dart`); token lookups are cached per theme; the conversation list is
lazy and keyed; contact-photo futures are cached; effects, ripple avatars and spinners stop by themselves; glass blur
is in menus, popovers and call screens, not the everyday screen (and `--dart-define=GHOST_PLAIN=true` turns the kit's
blur off: an option for the Linux build); game sensing does not run on Linux.

## What is left

1. **Measure on Linux.** Everything above was reasoned and tested on a Mac. `glxinfo | grep "OpenGL renderer"`
   first; then `flutter run --profile` with the performance overlay, or `integration_test/desk_frames_test.dart`.
2. The list of conversations as one `State` (finding 2's remainder): split what Voice, Summaries and the networks
   each change into their own listeners, if a profile still shows its builds.
3. The stores read whole at start, and a store a chat rather than one file (finding 4's remainder), if start-up or
   memory shows it.

# The phone's battery: calls and a paired computer (2026-11-24)

Matt, 2026-11-24, with Android's battery page showing Uplink at 17.1% for the day under "High CPU usage":
"please see what you can do about the high CPU usage on the app run some profiling on an emulator on this machine",
and "I suspect a large cost is in the voice calling so make sure we test every part of the app". Read at 0.12.25.

**How it was measured.** A profile build (`flutter build apk --profile`) on two Android 16 emulators on a Mac, each
signed in to a relay of this branch run on the Mac, friends with each other, in real calls with each other. Two
numbers for each state, over 20 to 30 seconds: every thread's CPU time from `/proc` (`tool/perf/threads.py`), and
where the Dart went, from the VM's sampling profiler (`tool/perf/cpu_profile.dart`); and `simpleperf` for which
library a thread's time was in. Percentages are of one emulator core. **Nothing here was measured on a phone:** the
emulators had no sound to capture or play (silence was encoded and sent), a real phone's cores and radio are not an
emulator's, and what the Fold itself spends was never read. The order of the findings should hold; the numbers are
the emulator's.

How to set it up again is at the end.

## What each state costs

| State (one phone) | Before | After |
|---|---|---|
| Signed in, the list on the screen, nothing happening | 0.03% | the same |
| The spaces list, a friend sitting in a space | 0.1% | the same |
| Scrolling the list | about 10% | the same |
| Alone in a voice space, the app put away | about 7% | 0.03% |
| Alone in a voice space, on the screen | 7 to 11% | the same (see "left") |
| A call with one other person, on the screen | 9.0 to 9.4% | about 1.5 less (8.0 to 9.7% read) |
| A call with one other person, the app put away | 9.5% | about 2.5 less (7.5 to 8.6% read) |
| An open space with one other, standing still | 10.0% | not measured again |
| An open space, walking | 14.5% | not measured again |

**A call's totals don't compare cleanly between runs.** WebRTC's own sound threads read differently from one run
of the app to the next by more than what was saved (the capture thread alone between 2.5% and 3.6% for the same
call), so the last two rows give what the threads that did the removed work stopped spending, which read the same
every run: the signalling thread from 0.6 to 0.8% down to under 0.07%, Android's garbage collector from 0.35 to
0.96% down to about 0.1%, and the app's main thread from 0.9 to 1.3% down to 0.6 to 0.8% on the screen and to 0.03
to 0.07% put away; against that, a tap on a voice adds 0.1 to 0.3% to the playout thread while the app is seen.

A phone with nothing going on is as quiet as it can be. What costs is a call, whether or not anyone is looking at
it, and (not measured, read from the code) a paired computer's asking.

## Findings

### 1. Alone in a space, the phone ran a whole call to itself (fixed while out of sight)

To ripple this device's own face while nobody else is in the call, `RtcMedia._openMeter` makes two connections on
the device, one sending the microphone to the other (Matt, 2026-11-16: "even when we're in the call alone we see the
voice activity of ourselves"; a sender that never connects is never started, and gave no level). That is the
microphone captured and cleaned, Opus encoded, sent, received, decoded and played at no volume, with both
connections' statistics read 6.7 times a second and the far end's volume set to nothing again at each reading: 7% of
a core for as long as someone sits in an empty space, behind a wake lock (CallService), screen on or off.

**Fixed** for the app out of sight (`lib/app_seen.dart`, `RtcMedia._seenChanged`): put away, the meter is closed and
nothing is read; brought back, it opens again at the first reading. A phone left alone in a space with its screen
off now runs no sound at all (0.03%). **Left:** on the screen it is as it was. The Mac's native half can say how
loud the microphone is without a connection (`VoiceFx.level`, used by the microphone test); the phone's could now
too, but starting the microphone without a connection on Android (`prewarmRecording`) and handing over to a real
call when someone joins was not something an emulator with no sound could prove.

### 2. How loud each voice is was read from WebRTC's whole statistics, 6.7 times a second for each person (fixed on the phone)

`RtcMedia._readLevelsOnce` asked every connection for `getStats()` every 150 ms and read one number from it. Each
asking has WebRTC gather the whole report on its signalling, worker and network threads, the plugin turn it into
maps, and Dart read them: the signalling thread 0.6 to 0.8% of a core, Android's garbage collector 0.3 to 1.0%, the
main thread about 0.5% and Dart 1.1%, for each person in the call, and the same with the app put away.

**Fixed:** on the phone the native half measures the voices itself (android `VoiceFx.kt`: the microphone's loudest
sample in the capture hook, everyone else's from a tap on their decoded track, as the call recorder taps them), and
one small `levels` answer holds them all. A connection's statistics are read every three seconds, for its round
trip alone (`RtcMedia.linkEvery`). Where a voice can't be tapped it is read from the statistics as before, and so is
everything on the Mac, Windows, Linux, an iPhone and in a browser. With the app out of sight nothing is read and
the taps are taken off. After: the signalling thread and the garbage collector at next to nothing, the main thread
0.6 to 0.8% on the screen and 0.03 to 0.07% put away. A tap is not free (0.1 to 0.3% on the playout thread for each
voice, while the app is seen).

### 3. A space's ids were derived afresh at every asking (fixed)

`VoiceChannel.room`, `token`, `key`, `chatRoom` and `chatToken` were each a hash in pure Dart every time they were
read, and a list of spaces reads `room` for every row and a call for every message it sends: walking an open space
spent a twentieth of its Dart deriving the same room. `Roster.ownerId` hashed the owner's key for every row a
space's page drew, a tenth of that page's build. Each is now worked out once and kept.

### 4. A paired computer asked for everything every eight seconds (fixed; not measured)

Read from the code, not measured: no computer was paired with the emulators. A computer's app asks the phone for
its spaces and circles every 8 seconds (`Voice.syncNow`) and its friends every 20 (`Buddies.refresh`), and was
answered with all of them each time: every circle whole, up to 60 KB each with its picture. The phone made the
answer, sealed it and sent it, on the local network or through the relay, for as long as the computer's app was
open. `lib/desk_stamp.dart`: the computer now says the mark of the answer it has, and the phone answers `same`
while nothing changed; the spaces are still taken whole every two minutes, which is what hands the phone a space the
computer made while it was away. The asking itself still comes every 8 and 20 seconds, and the link's ping every 20:
each wakes the phone's radio. Telling the computer when something changes, in place of being asked, is what would
stop that.

## What a call still costs, and what would lower it

After the fixes a quiet call with one other person is all WebRTC's own work: the microphone captured and cleaned
(2.7%, about a third of it RNNoise), Opus encoded (1.1%), the network (1.4%, most of it the emulator's own cost for
a packet), the other voice decoded and played (1.3%), 0.5% beside. Each further person adds an encoder, a decoder
and a connection. None of it was changed. Asked of Matt, not done:

- **Muted, the microphone is still captured, cleaned, encoded and sent** as silence. Letting go of the microphone
  while muted would take off about half of what a muted person in a space costs, and the phone's microphone light
  with it; unmuting would take a moment to start it again.
- **Opus's discontinuous transmission** (`usedtx=1`) sends next to nothing while nobody speaks, for both ends.
- **The meter while alone and on the screen** (finding 1).

## Looked at, not changed

- Everything the app remembers is one Android SharedPreferences file ("ui"), written whole at each change. A
  space's messages are kept there, at most 300 a space, written again for each message. Small on a new account
  (21 KB); how large it is on a phone in many circles was not seen.
- A call's page builds itself again every second for its clock (`_SpaceCallPageState`): cheap once finding 3 was
  fixed, and not at all with the app put away.
- `_silenceSink` sets the meter's far end to no volume at every reading while alone: gone with the meter.
- Direct (the node on the direct network) starts no thread until there is someone to reach.
- Cosmetics that move (`lib/ui/cosmetics_ui.dart`) repeat for as long as they are on the screen. Not measured: the
  test accounts had none.

## The Mac freezing as a call starts and ends (found and fixed 2026-11-24)

Matt, 2026-11-24: "connecting to a call still freezes the mac and shows a pinwheel animation", then, on the
MacBook Air, "it lagged on the call end". Sampled on that Mac with `sample <pid> 15 5` back to back while he joined
and left a call in 0.12.26 (whose Dart macOS names, the build's `App.framework.dSYM` being on the disk), and read
with the scripts beside the samples in `build/mac-hang`.

Both were the same shape: **the app's main thread waiting on WebRTC while WebRTC waited on the system's sound.**
On a Mac flutter_webrtc uses Apple's audio engine with its voice processing, and starting or stopping the
microphone there takes about three seconds on WebRTC's worker thread (`AudioEngineDevice::InitRecording` →
`-[AVAudioEngine prepare]` → `AudioUnitInitialize`, waiting on CoreAudio's lock while `coreaudiod` rebuilds the
device's IO context). That alone freezes nothing. But flutter_webrtc answers every call from Dart on the main thread,
and some of its answers ask the worker thread and wait:

- **Joining (3.2 s):** `getReceivers` → `-[RTCRtpReceiver parameters]` → a blocking call to the worker, while the
  worker was in `InitRecording`. The app asked for the meter's receivers at every level reading, 6.7 times a second
  (`RtcMedia._silenceSink`, to keep this device from hearing itself), so one of those was always in the way.
  **Fixed:** the meter's far end is silenced by the tracks its connection announces, and the platform is told only
  when something changes; the connection is asked for its receivers on Android alone, every two seconds.
- **Leaving (2.6 s):** `peerConnectionClose` → `PeerConnection::Close()`, which waits while the worker stops the
  sound. **Fixed** on the Mac: the native half closes the connection first, on another thread
  (`macos/Runner/VoiceFx.swift` `closeConnection`, `RtcMedia.closeConnection`), and the plugin's own close then
  finds it closed.

**Not seen on the Mac since the fix** (it needs a release to try), and left as they are: `getSenders`,
`getTransceivers` and `setParameters` where a connection is set up or its bitrate retuned (`_fillOwn`, `_highest`),
which ask the same threads; and the three seconds themselves, which are Apple's voice processing starting. Without it
(`bypassVoiceProcessing`) the engine starts in a few hundredths of a second, and echo cancelling would be WebRTC's
own: a change for ears to judge.

**What the screens say meanwhile** (Matt, 2026-11-24: "show better loading states with skeletal loaders and a
connecting banner so it doesn't just seem like the app is frozen"). The three seconds are still three seconds, so the
call says what it is waiting for: it is drawn as soon as Join is pressed (`Voice.joining`, and the screens told before
the chat's room is opened), with a line at its top, an arc turning in it, that reads "Connecting… Starting the
microphone", then "Joining the call", then "Reaching Maya" until someone can be heard (`lib/voice/call_wait.dart`,
`lib/ui/connecting_banner.dart`; `RtcMedia.micLive` is the microphone having been heard at all). Leaving is said to
the screens at once and the closing goes on behind (`Voice.leave`, `_leaving`): the call stood there for the 2.6
seconds as if Leave had not been pressed. An arc that turns is also the plainest test of the fix: if the main thread
is held again, it stops.

Also in those samples, from 0.12.25 and so without names: bringing the window back from the Dock was followed by
about eight seconds of Dart on the main thread, a second and more of it handing something large to another isolate
(`SendPort.send`). Not found yet; a sample of 0.12.26 doing the same would name it.

## Reading a real phone

The Performance plugin (lib/plugins/performance.dart, lib/perf/app_usage.dart; Marketplace › Performance) measures
the app from inside it, on the device itself: a row under the title bar with the processor, memory and frames, a
count of spikes, and a log to copy with a line a minute that names the busiest threads on Android and Linux, read
on with the app put away. A log copied from the Fold after an hour of ordinary use, a call among it, is the
measurement this page does not have.

## Setting it up again

```sh
# A relay of this branch, and a stand-in for the call relay (below).
(cd relay && GHOST_TURN_SECRET=x GHOST_TURN_URLS=stun:10.0.2.2:34780 dart run bin/relay.dart --port 8787 --data <a new folder>)
# Two emulators; on each: the build, the relay's port, and the relay's address as the app's own choice.
flutter build apk --profile --target-platform android-arm64
adb -s <emulator> install -r build/app/outputs/flutter-apk/app-profile.apk
adb -s <emulator> reverse tcp:8787 tcp:8787
#   net_hub = ws://127.0.0.1:8787/hub in shared_prefs/ui.xml (adb root), or Settings › Routes › Relay server
python3 tool/perf/threads.py 30 <emulator>
dart run tool/perf/cpu_profile.dart ws://127.0.0.1:<port>/<token>=/ws 30   # the address is in logcat; adb forward it
```

Two emulators on one Mac can't reach each other for a call: each is behind its own network, and the app's STUN
servers tell each the Mac's address on the internet. `python3 tool/perf/emulator_stun.py` answers STUN on the Mac
(127.0.0.1:34780) with `10.0.2.2` and the port a packet came from, which gives each emulator an address the other can
reach; the relay hands it out as the call relay (`GHOST_TURN_URLS`). The app's second try at a connection is
through the call relay alone, which this stand-in is not, so a call there can take two or three tries (half a
minute) to connect. `adb shell setprop log.tag.GhostPerf VERBOSE` before the app starts has it count its frames.
