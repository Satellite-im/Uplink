# Forward secrecy and key rotation (GMFB-26)

From the Uplink gap review: "Forward secrecy and key rotation for friends and circles". Approved by Matt on
2026-11-22. This file is the design: what was built, what it protects, what it does not, the wire format, and how it
works with one account on several devices and with builds from before it.

> **Status.** The friends half (friends and an account's own devices) is on. The circle half is in two switches.
> `CircleKeys.enabled` (taking part) is **on** since 2026-11-26: every device holds an inbox and says it, takes a key
> handed to it, asks for one it lacks, and opens and seals under a circle's newest key. `CircleKeys.makes` (making a
> new key at a ban or kick) is **off**: no device makes one, so in practice circles are still sealed with their
> seeds' keys and banning someone doesn't change a circle's key yet. See "Switching it on" below.

Code: `lib/net/forward_secrecy.dart` (friends and an account's own devices), `lib/circles/circle_keys.dart` (circles),
with the switchboard (`lib/net/switchboard.dart`), the circle's room (`CircleRoom` in `lib/circles/circles.dart`) and a
space's chat (`HangoutRoom` in `lib/voice/hangout.dart`) using them. Tests: `test/forward_secrecy_test.dart`,
`test/circle_keys_test.dart`.

## Where things stood

- **Friends.** A packet between two accounts was sealed with the pair's key (`NetCrypto.netKey`), made by ECDH from
  the two accounts' long-term P-256 keys. Nothing else went into it.
- **An account's own devices.** Copies of conversations between the account's devices (GMFB-21) were sealed with
  `Me.mineKey`, which comes from the account's recovery words.
- **Circles.** A circle's room and its spaces' chat were sealed with keys made from seeds every member holds
  (`Circle.key`, `VoiceChannel.key`). Banning someone stopped their app from joining, but they kept the seeds.

So anyone who kept the packets (the relay, or anyone with a view of its traffic) and later learned an account's
recovery words could open everything that account ever sent or received, back to the first message. And a banned
circle member running a changed app could go on reading the circle silently.

## Threat model

The attacker we design against:

1. **Records traffic** passing through the relay: the operator, someone who breaks into the server, or anyone who can
   see its traffic. Today the relay can already see which ids talk, when, and how much.
2. **Later gets long-term secrets**: the account's recovery words, the account backup and its password, or the
   identity key. Or later **takes a device**, and with it everything stored on it at that moment.
3. **Is an active relay**: it can drop, delay, reorder and replay packets, and stamp any id on a room packet. It
   can't connect as an id without that id's key, because the hub checks a signature at hello.
4. **For circles, is a banned or kicked member**, possibly with a changed app. They keep the circle's seeds and every
   key they were ever given, and they can make new identities.

We do not try to defend against malware running on a device while it is in use, against someone who can read your
screen, or against the network learning who talks to whom. Uplink doesn't hide that today either.

## Friends, and an account's own devices

### Prekeys

Each device makes a P-256 key pair of its own, called a prekey. It is random, it is kept in the device's secret store
(the Keychain, or Android's vault, where the account's words are kept), it never goes into the account backup, and
it can't be worked out from the recovery words. A device:

- makes a new prekey every **day** (`rotateEvery`);
- deletes each prekey's private half **15 days** after making it (`keepFor`). That is 7 days in which others may
  still seal to it, plus the relay's longest hold of 7 days, plus 1 day of margin;
- offers its newest prekey inside every envelope it seals, as `f` in the envelope's JSON:
  `{"d": device, "p": prekey id, "k": public key, "m": made-at}`. A build from before ignores keys it doesn't know.

A prekey is believed because it came inside an envelope sealed by that peer: with the pair's key, or under forward
secrecy. So no signature and no server are needed. A peer holds up to 8 devices per account. It seals to a device's
newest prekey only while that prekey is less than **7 days** old (`useFor`), and it won't take a prekey whose
made-at time is more than a day in the future.

### Sealing a packet

When the other account has at least one device with a prekey this device can use, the packet is sealed like this:

1. Make a fresh P-256 key pair for this one packet. It is never stored and is dropped as soon as sealing finishes.
2. Make a random 32-byte content key, and seal the envelope with AES-256-GCM under it.
3. For each of the other account's devices, wrap the content key:
   `k = HKDF-SHA256(salt = pair's key, ikm = ECDH(one-off, device prekey), info = "ghost fs v1 wrap" | from | to | device | prekey id | one-off public)`,
   then seal the content key with AES-256-GCM under `k`.

The pair's key in the salt is what authenticates the sender, as it did before. The packet's flag byte gets bit 4
(`Packet` flags: 1 sealed, 2 part, 4 forward-secret). The last field is laid out like this:

```
[1: n, the number of devices][33: the one-off public key]
n × [16: device id][4: prekey id][12: nonce][32+16: the content key, sealed]
[12: nonce][the envelope, sealed under the content key][16: tag]
```

The envelope's additional data is `"ghost fs v1" | from | to | everything before it`, so entries can't be swapped,
added or removed. Copies to the account's own devices use the same scheme. There, `from` and `to` are both the
account's id, the salt is the words' key, and the targets are the account's other devices.

The primitives are only ones the app already used: P-256 ECDH (pointycastle), HKDF-SHA256 built from the existing
HMAC, and AES-256-GCM (`FastGcm`). There are no new ciphers. Each EC operation takes about 7 ms in a debug build, so
sealing for three devices takes about 20 ms. The old sealing takes about 0.06 ms. So sealing and opening run on one
long-lived worker isolate, not on the one that draws the screens. Jobs go through it in a queue, in the order asked.
What arrives is handled one packet at a time, in the order it came, so a ring, its cancel, or an edit can't be
reordered by one packet taking longer to open than the next. The worker is supervised:
- each job has 5 seconds;
- if the worker dies or errs, every job waiting is failed and the next job starts a new worker;
- a start that failed is not kept.

A job that fails is done on the main isolate instead, so a packet is never stuck and the queue moves on. A packet
that can't be opened even then is dropped, not acknowledged. Old-sealed packets wait their turn behind forward-secret
ones rather than skip ahead, to keep the order.

Acknowledgements and `fsk` carry nothing worth keeping secret, so they get the old sealing (still with our prekey in
them).

### Opening, replays, deletion

- A device looks for the entry with its own id and opens it with the matching prekey, if it still holds that prekey
  and it is younger than `keepFor`.
- **Replays.** A tag of each one-off key opened is kept with the app's choices: the newest 5,000, each dropped when its
  prekey is deleted. A packet seen before is acknowledged again but not passed on, even after a restart. This matters
  because the switchboard's in-memory duplicate list is lost when the app starts again.
- **A packet this device can't open.** If there is no entry for it (the sender hadn't heard of it yet), its prekey
  is gone, or its own forward secrecy hasn't loaded yet, the device doesn't acknowledge the packet. It does two
  things instead:
  - It sends back an `fsk` envelope carrying its prekey, at most every 10 minutes per peer. The sender's switchboard
    keeps every sealed envelope of every kind that hasn't been acknowledged for 5 minutes (at most 200). On an `fsk`
    it sends them again, sealed anew so the new device is included. That covers calls ringing, group messages, buddy
    messages and copies, not just the texts Friends re-sends itself. A ring older than its ringing time (35 seconds),
    or one whose cancel is also waiting, is not sent again. A device receiving a ring more than 35 seconds old (plus
    30 seconds for clock skew) shows it as missed rather than ringing.
  - It passes the packet on, still sealed, to its own account's id, so a sibling can open it. The relay hands it to
    a sibling, or keeps it for whichever comes first. This is limited:
    - only if the header names any device other than this one. The device needn't know the other device: one back
      after more than a week has forgotten its siblings;
    - this applies whether or not forward secrecy is loaded here;
    - a packet passed on by another device of the account (flag 8) is not passed on again;
    - each packet once, remembered across restarts. One that comes back to the device that passed it on (it was the
      only device online, and the relay handed the held packet back to it) is put back on the account's id, at most 3
      times in all;
    - at most 256 KB per 10 minutes.
    A relay updated with this change no longer hands a device back the own-id packets it sent itself. It keeps them
    for the account's other devices, so that bounce stops happening. The app doesn't depend on that.
    The hub stamps each packet with the sender it authenticated. A packet whose own `from` doesn't match that stamp
    (or, for one passed on, isn't the account's own id) is dropped.
- **Forward secrecy that can't load** (an iPhone's Keychain can't be read before its first unlock) is tried again
  every 30 seconds and whenever the app comes back. Until it loads, the device sends everything the old way with no
  prekey. To a forward-secret packet it can't open, it does two things:
  - it answers with an `fsk` saying which device it is and that it has no forward secrecy (`{d, nofs: 1}`);
  - it passes the packet on to its siblings.

  The sender then sends that account an old-sealed copy of each envelope besides the forward-secret one, until that
  device offers a prekey. That happens as soon as it loads and sends anything, and the old copies stop. Its other
  devices go on getting the forward-secret packet. Whatever was unacknowledged goes again at once.
- **A new prekey** goes into the secret store before it is used or offered. If the write fails, nothing changes.
- **Deletion.** The one-off private key is never kept anywhere. A prekey's private half is removed from memory and
  from the secret store at `keepFor`, and it isn't used even before the deletion actually runs. Signing out deletes
  everything (`ForwardSecrecy.wipe`).

### When it falls back to the old sealing

- **A peer that has never offered a prekey** (a build from before, or someone not yet heard from since updating):
  the old pair's-key sealing, exactly as before, with our prekey added. Their answer brings theirs.
- **A peer's device gone quiet** past 7 days (`useFor`) is forgotten. Packets are sealed for their other devices only,
  still forward secret. If the quiet device comes back and gets one, it can't open it: it answers with `fsk` and
  passes it on to its siblings, as above.
- **A peer with a device that can't do forward secrecy.** This is known in two ways:
  - an old-sealed envelope with no prekey in it, from an id, over a route that carries prekeys. That means a build
    from before, which can't say which device it is;
  - an `fsk` with `nofs` from a named device.

  For 7 days after that (`oldDeviceFor`), every envelope to that id also goes as an old-sealed copy, which the device
  reads. The id's other devices still get the forward-secret packet. For a named device, the copies stop as soon as it
  offers a prekey. This applies to friends and to the account's own id (copies to an old sibling).
  - It counts only from an envelope that is new (its id not seen before, checked after the duplicate check) and
    current (its time within 5 minutes of now). So a replayed old packet can't turn forward secrecy off.
  - Duplicates are dropped by envelope id, as before.
- **Small routes.** Data texts (the SMS route, 133 bytes a part) always get the old sealing, with no prekey added, so
  a ringing call still fits in one text.
- **Receiving.** Packets sealed the old way are always accepted. Otherwise one old device of an account, or a stale
  prekey, would lose messages.

### One identity on several devices

An account is one identity with one id on every device. The relay hands a packet for an id to every connected device
of that id, or holds it for whichever device connects first. That rules out a classic per-device Double Ratchet:
the packet has to open on any device of the account that gets it. So a packet carries one wrapped key for each
device of the account that has offered a prekey. Every device in that list can open it on its own. Out-of-order and
lost packets need no special handling, because each packet stands alone and there is no chain state to fall out of
step.

- A new device, or one the sender hasn't heard of, answers with `fsk` and passes the packet on to the siblings it
  knows, as described above. The sender sends again, sealed for it too, whatever it hasn't had acknowledged.
- A build from before on one of the account's devices never offers a prekey. Once it has sent anything, everything
  to that account also goes as an old-sealed copy for a week, so it reads it. Until it has sent something, it is unknown: what it
  gets sealed for its siblings it can't open, and it can't pass on or ask, so that is lost to that old device. The
  siblings still get it.
- Device sync of history (GMFB-21) keeps working. Copies go to the account's own id, sealed to the siblings'
  prekeys, or the old way while a sibling without forward secrecy has been heard from.

## Circles: a new key when someone is put out

Taking part (`CircleKeys.enabled`) is on; making a new key (`CircleKeys.makes`, checked in `Circles.rotateKey`) is
off. With making off, nothing below that starts at a ban happens; everything a device does with a key it is handed
does.

### Switching it on

Making a key locks every build from before taking part out of that circle at its first removal, and that can't be
undone for a circle. So, in steps:

1. **Every device takes part, none makes a key** (2026-11-26, `enabled` on, `makes` off). Devices that update hold
   inboxes and can take and read a key the day one is made. Nothing changes for anyone meanwhile. Tested:
   `test/circle_keys_test.dart`, "a device that doesn't make keys changes nothing at a ban, and still takes and reads a
   key a device that does made".
2. **Close the gaps for chat and calls** below ("Not built yet"): a brand-new device sealing with the old key, call
   setup, packets under an old key taken forever.
3. **Switch `makes` on** once nearly every device has updated past step 1 (Matt's call: it is the moment older builds
   stop reading a circle that bans someone).
4. **Files spaces** under epochs.

### Epochs

When the owner or an admin **bans** (`removeMember`) or **kicks** (`kickMember`) someone, their device does this:

1. Publishes the manifest saying so, sealed under the current key, so the person's own app still sees it and leaves.
2. Makes a random 32-byte key for epoch `e + 1` and signs a header:
   `"ghost-circle epoch v1|seed|epoch|commit|by|byKey|at"`, where `commit = HMAC(key, "ghost-circle commit v1|seed|epoch")`.
   Members believe a header only if it is signed by the owner or an admin of the circle (`CircleManifest.canSign`).
3. Seals the key separately to each eligible member's devices (see "Inboxes" below):
   `HKDF(salt = Circle.key, ikm = ECDH(one-off, inbox), info = "ghost-circle box v1|seed|epoch|commit|id|device")`, then AES-GCM.
   The person put out gets no box.
4. Says it in the circle's room (`rk`, then `kb` for every 200 boxes). The relay keeps these messages for devices
   that come in later.

From then on, the circle's spaces' chat and reactions (and the room's `was`) are sealed under
`HKDF(salt = epoch key, ikm = the seed's own key for that room, info = "ghost-circle epoch v1|purpose|epoch")`, laid
out like this:

```
[3: "GE1"][4: epoch, big-endian][4: commit's first 4 bytes][12: nonce][AES-256-GCM output][16: tag]
```

The additional data is the 11-byte head plus `|purpose` ("circle" for the room, "space" for a space's chat). The seed
alone opens nothing sealed after a change. A key from one epoch opens nothing from a later one. Members keep every
epoch key they've held, so earlier messages still open.

- **The circle's own business stays under the seed's key:** its manifest, `sync?`, joins, inboxes, boxes and asks.
  A member who is behind on the key must still hear the circle change, be told they were put out, and say they came
  back. Otherwise they would wait on a key nobody gives them. So someone put out can still read the manifest: the
  circle's name, its spaces and roles. They can't read what is said in its spaces.
- **Never under an older key.** A device that knows of a newer epoch than it holds a key for (or knows the circle
  has epochs but holds none) seals nothing in the circle's spaces. It doesn't use an older key, and it doesn't use the
  seed's. It keeps what it would have said, at most 100 items, saved with the space so a restart doesn't lose them,
  and asks for the key. Reactions wait as reactions. Everything goes as soon as nothing newer is lacking, whatever
  caused that. Meanwhile the space shows "Waiting for the circle's new key".
- **Unreadable packets wait.** A packet under an epoch this device doesn't hold is kept (the newest 200 per room). The
  circle's room asks for the key, and the packet is opened when the key comes.
- **Headers are judged as they're taken.** A header carries the admin list generation (`gv`) its signer could sign
  under, signed in. A device takes a new header only if its signer may change the circle now. Once taken, a header
  stays believed until a newer epoch supersedes it, even if its signer later stops being an admin. Dropping it would
  make the device fall back to an older key, or the seed's, which the person put out holds. When the owner demotes an
  admin who made the newest key, the owner makes a new one, so members who come later (and won't take the demoted
  admin's header) aren't stuck. Any epoch up to `0xffff0000` is recorded as known, so a device far behind knows it
  lacks the newest and seals nothing. Higher epochs are refused, because the field is 32 bits.
- **Two admins at once.** If two believed headers name the newest epoch with different keys, the lower commitment
  wins. Only the device that made the losing header changes the key again, after a random wait of 0.3 to 2.3 seconds,
  if it's still split then, and once per epoch. Another device of the same identity didn't make it, so it doesn't.

### Inboxes, and coming in later

- Every member's device has a random inbox key pair for circle keys. It is kept in the secret store and isn't made
  from the recovery words. The device announces it in each circle's room as `ik`, signed by its identity, with
  `idOf(key) == from`.
- The inbox is said to be kept by the relay at most once a day per circle. Otherwise it is said live, so the room's
  300 kept packets don't fill with inboxes. At most 8 inboxes are kept for one id.
- A device that knows of a newer epoch than it holds a key for asks with `k?`, its inbox and `ke` (the newest epoch it
  holds). It learns of newer epochs from kept `rk` and `kb` messages, from a packet it can't open, or from a header
  hint (below). A device that holds the keys answers with a `kb` box for **every** epoch after `ke`, oldest first, so
  a device that was away through several changes reads each. Answers are timed the same way as manifest answers: the
  lowest id goes first, and the others wait a step and drop out if they hear the answer. A device that was asked while
  it lacked the key too answers once it has it, staggered the same way. Each device's `k?` is answered at most every
  10 seconds.
- **A kicked member who comes back** is handed only epochs whose header was made after they said they came back. If
  there are none, the owner or an admin makes a new key, which they're in. So nothing said while they were out opens
  for them. Their return is visible to everyone, and a `joined` prompts a header hint, so they know to ask.
- `sync?` now carries `ke`, the newest epoch the asker holds. A device holding a newer one replies with just the
  signed header. That tells the asker to ask, even after the relay's kept messages have expired.
- **Who may be given the key** (`Circles.mayHaveKey`): the owner, admins, the identity's own devices, and anyone the
  circle has seen openly: anyone noted in its members list, or whose join was heard. They must also not be banned,
  and not kicked since they last said they came in. When each member last came in is kept on the device
  (`circles_last_join`), so this survives a restart. Someone who slips into the room with its token and is never
  seen (a banned member under a new key, for instance) is not given the key. To get it, they have to come in the way
  anyone does, and every member is told about that.
- A box is believed only if its key matches the commitment in a header the owner or an admin signed. So a removed
  member can't hand out a key of their own to people who'd then post under it. They can still replay real headers.
  Cancelling pending answers needs a header signed by the owner or an admin, from someone who may hold the key.
- **A banned member who comes back through the link** can't read the manifest that names them, because it is sealed
  under a key they aren't given. So the owner's or an admin's device answers their `sync?` with `out`: a statement,
  signed by that device and valid for 10 minutes, that this id is banned. Their app leaves, as it did before.
- `inbox`, `rk`, `kb`, `k?` and `out` are sealed with the seed's key, because a device without the newest key has to be able
  to read them. They contain only public keys, signatures and boxes.

### Mixed versions in circles

- A build from before keeps sealing with the seed's keys. Newer builds still open what it sends.
- After a change, a build from before **can't read** what newer builds post in the circle's room or its spaces'
  chat. Once it updates, it asks and is given the key. Messages the relay kept (7 days, 300 per room) then open when
  it next joins the room.
- Browser guests in a circle space (`site/join`) don't know about epochs, so after a change they can't read the
  space's chat.

## What is protected, and what is NOT

**Protected:**

- **Messages between friends, and copies between an account's own devices, sealed with forward secrecy,** against
  someone who recorded them and later gets the account's recovery words, its backup and password, or its identity
  key. Those are not enough to open them, ever. This holds for every envelope kind that goes through the switchboard,
  including friend requests, texts, calls being set up and groups of friends.
- **The same messages against someone who later takes the device,** once the prekey they were sealed to has been
  deleted. That happens at most 15 days after the prekey was made, and the prekey was made at most a day before the
  message in an ongoing conversation.
- **Passive healing.** Someone who copied a device's secrets but doesn't interfere with traffic loses the ability to
  read new messages once the device has made a new prekey (within a day) and its friends have heard of it.
- **Circles: nothing yet.** The circle half is switched off, so circles are sealed with their seeds' keys as before.
  A banned member who kept the seeds can still read a circle with a changed app.
- **Replays** of forward-secret packets are acknowledged but not delivered again, even across restarts, while the
  packet is among the newest 5,000 opened or its prekey still exists. After that its prekey is gone, so it can't be
  opened at all.

**Not protected:**

- **Anything stored on a device.** Your message history is kept on your devices. Whoever takes a device reads what's
  stored there, forward secrecy or not. Forward secrecy protects traffic that was recorded, not your history.
- **Traffic recorded before this release,** and anything sealed the old way. That includes:
  - the old-sealed copy sent for a week to an account (yours included) that has a device without forward secrecy: a
    build from before, or one whose Keychain wasn't unlocked yet. Copies to a named device stop once it offers a
    prekey. Anyone who recorded the old copy can open it with the long-term key;
  - everything to and from builds from before;
  - acknowledgements and `fsk` (which hold no content);
  - data texts (SMS route).
- **Active attacks after long-term secrets leak.** With an account's identity key, an attacker can seal messages as
  that account and offer their own prekeys, which makes them a man in the middle from then on. Forward secrecy is
  about the past. It doesn't stop impersonation in the future. Safety numbers are still how you check.
- **Who talks to whom, when, and how much.** A forward-secret packet also shows how many devices it was sealed for,
  and their device ids. The relay already knows those from the hello.
- **Encrypted texts with a phone number** (`E2e.kt`, the "Send my key" encryption for SMS) are a separate system and
  are unchanged.
- **Circles, entirely, for now.** The circle half is switched off (see Status). Once it is on, the design still
  leaves the following open.
- **Circles are not forward secret.** Members keep every epoch key they held, and a stolen member's device opens
  every epoch it held. Rotation is about people put out, not about time.
- **Leaving a circle doesn't change its key.** Leaving can't be told apart from going offline, and anyone who keeps
  the link can come back. A scheduled rotation isn't built either.
- **A banned member can still see the circle's traffic:** who is in its rooms, and when and how much is said. They can
  also come back openly under a new identity through the link, if they still have it. Members see them join, and
  can ban them again. Links themselves can't be revoked yet.
- **Not covered in a circle:** files in its Files spaces, and the call signalling of its voice spaces (call audio and
  video were already sealed per call by WebRTC). Spaces that aren't in a circle are also not covered. For all of
  these, the seed is still the key.
- **A member the circle has never seen** come in or write is not given the key until they do.
- **The manifest** (name, spaces, roles) is readable by someone put out, as above.
- **A device that hasn't heard of any epoch yet** (a brand new device, before the relay's kept `rk` or a hint
  reaches it) seals with the seed's key, because it can't know better. This is the main reason the circle half stays
  switched off.

## Compatibility rules (summary)

| Sender | Receiver | What happens |
| --- | --- | --- |
| New | Old build | Old sealing. Our prekey goes in `f`, which the old build ignores |
| Old build | New | Old sealing, accepted as always |
| New | New, prekey heard within 7 days | Forward-secret sealing for every device of theirs heard from |
| New | New, one of their devices quiet 7 to 15 days | Old sealing until it answers with a fresh prekey, or is forgotten at 15 days |
| New | An account with a device without forward secrecy in the last 7 days | Forward-secret packet plus an old-sealed copy for that device |
| Any | Acknowledgements and `fsk` | Old sealing, with the prekey |
| Any | Over data texts (SMS) | Old sealing, nothing added |
| Circle, new, epoch held (switched off) | Circle, old build | Old build can't read it until it updates and is given the key |
| Circle, old build | Circle, new | Seed's key, accepted |

**Relay:** nothing is needed. Prekeys travel inside sealed envelopes, and circle keys travel in the circle's room as
kept packets. A relay that knows nothing about this carries all of it. One optional relay change is written and
tested (`relay/lib/hub.dart`, `relay/test/devices_test.dart`) but not deployed: a packet a device sends to its own
name while nobody else of it is online is kept for the account's other devices, not handed back to that device. It
saves passed-on packets from bouncing back. The app works without it.

## Not built yet

- One-time prekeys (per-message deletion on the receiving side), or a ratchet per pair of devices. Both would shorten
  the 15-day window for a stolen device. The multi-device hand-off would need to change for either one.
- Rotating a circle's seed and links, so a banned member can't come back through an old link.
- Epochs for circle Files spaces and voice-space signalling, and for browser guests.
- Scheduled circle rotation.
- A way to see, in Settings, which friends' devices get forward-secret messages.
