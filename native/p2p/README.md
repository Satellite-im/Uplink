# ghost_p2p: the direct network's core

The Rust half of Uplink's direct route (`docs/OPEN_NETWORK.md`, section 2; Matt, 2026-11-22: "look at iroh
as the rust backend for the p2p side"). A **node** is one device: a key made on the device, whose public half is its
**node id**. A node offers one thing, framed streams to another node by its id on a numbered **channel**, and says
how the path to each linked node stands. It is built on [iroh](https://github.com/n0-computer/iroh) 1.5 (QUIC,
hole punching, relay servers as a fallback, which the app calls **link helpers**).

It carries bytes and nothing else: who may link, what a frame means, when a phone's node is up are all the app's, in
Dart, behind `lib/net/p2p/node.dart` (`P2pNode`). `lib/net/p2p/node_ffi.dart` is this library's one caller.

    src/node.rs    the node, and every rule it keeps
    src/wire.rs    commands and events as bytes
    src/ffi.rs     the C interface (include/ghost_p2p.h), and the messages it posts to Dart
    src/tests.rs   nodes in one process, linked over loopback and through a link helper inside the test

## What it never does

- **Look anyone up, or publish where it is.** The endpoint is made with no address lookup at all (no DNS or pkarr
  record, no DHT, no mDNS). A node is dialled only by what the app hands `OPEN` (where the other device last said it
  is) and by what iroh has learnt of it over a link since this node came up.
- **Talk to a server the app did not name.** Link helpers are the ones `START` names; with none, relays are off. A
  hint's helper is used only when it is one of this node's own, whoever sent the hint (iroh would otherwise connect to
  any relay address it is handed). The helper's name is asked of the system's own DNS servers and of no public
  resolver behind them (iroh's default falls back to Cloudflare, Google and Quad9; that is turned off).
- **Dial what a hint names that is no other device's address**: this device's own (loopback), or one that means
  nothing off a link or everything at once (unspecified, `0.0.0.0/8`, link-local `169.254.0.0/16` and `fe80::/10`,
  multicast, broadcast), in whatever form an IPv6 address carries an IPv4 one (mapped, the old compatible form, or
  the NAT64 prefix). A friend's word in a hint cannot point this node at itself or at the services of its own
  network. (The crate's own tests, two nodes on one machine, dial loopback; the library built for the app never
  does.) What it does not cover: QUIC's hole punching inside iroh, which sends a small probe to whatever addresses the
  other end of a link names, loopback included (see "What a node that links can make this one send").
- **Hand over an open to a node disallowed while it was dialled.** DISALLOW closes the links it finds; a dial under
  way then makes its link after, so the open looks once more when it is done, and a node disallowed since it was asked
  has its link closed and the open fails (TurnedAway).
- **Take another node key's port.** The port a node asks for again is the one it had on that network with that node
  key: another account signed in on the same device is not found on the first one's port.
- **Ask a link helper's name anything but what the helper is there for.** See "What a link helper is asked". iroh's
  captive-portal check is off: it asks `http://<the helper's name>/generate_204`, in plain HTTP on port 80 whatever
  the helper's own port, and where port 80 there is another server's, takes its answer for a captive portal.
- **Take early data.** QUIC's 0-RTT lets a device that has linked before send streams with its first packet, before
  the handshake has ended; anyone who saw that packet could send it again. iroh's TLS takes it (and has no switch for
  that), so this library looks: a stream that comes while the handshake is under way came in early data, and the link
  is closed for it. (A device modified to hold its early data back until its own handshake has ended could still have
  it taken; this library's own nodes never send any.)
- **Open a port on the router.** iroh's port mapping (UPnP, NAT-PMP, PCP) is not compiled in, nor its metrics, nor
  the faster datagram calls that are private to Apple's systems.
- **Believe a length.** A frame's length is checked against the most before anything is set aside for it, and its
  memory grows only as its bytes arrive (doubling, from 64 KiB, and never past the length).
- **Grow without bound.** See "What is counted".
- **Call into Dart.** See "The C interface": events are messages to a port, so nothing here can call an isolate that
  has gone.

`helpers_only` binds no socket of this node's own: every packet goes through a link helper, and the other device
sees the helper's address. Such a node says where it is by its helper alone, never an address, and has nothing to
send a hole-punching probe from (see "What a node that links can learn").

### What a link helper is asked

A link helper is an iroh relay server, and is made from its https address alone, as `START` wrote it: a port and a
path are kept (`https://link.example:7843`), and no token goes with it. Its certificate is checked against the
roots compiled into the library (Mozilla's), not the system's. Three things are asked of it, all at that one name:

| | |
| --- | --- |
| The connection links are made through | HTTPS (a WebSocket) at the address itself, kept open while the node is up, with a ping every 15 seconds |
| How far away it is | an HTTPS GET of `ping` under the address, when iroh looks at the network |
| Where this node is seen from | QUIC on UDP port 7842 (iroh's usual port, which a helper keeps to; there is no saying another). Not asked by a `helpers_only` node, which has no socket to ask from |

A helper that asked for a token would be given it here too: iroh sends one as a bearer header on the first of
these. That is not built. The token would follow its helper's address in `START`, under a new interface number, and
be handed to iroh where a helper is made (`helper` in `src/node.rs`); nothing else would change.

### What it tells others of where it is

`WHEREABOUTS` (which the app tells friends and its own devices) holds where the internet sees this node (an address
no interface of this machine has, which a link helper said) and the addresses of the interface its route to the
internet goes by: the network it is on. (That interface is found by asking the system which of its addresses it
would send from towards an address of the ranges kept for documentation: a UDP socket pointed there sends nothing.
The interfaces are listed as the system lists them; nothing is run in a process of its own.) Where that interface cannot be told, or is a tunnel (a VPN that takes the
route), those of every interface but a virtual machine's or a tunnel's (VPN tunnels, WireGuard, Tailscale,
ZeroTier, bridges to virtual machines, Docker, Apple's AWDL and LLW, Android's Wi-Fi Direct and CLAT). Never
loopback, link-local or an address the system no longer means to use; where an interface has an IPv6 privacy
address, not its lasting one. Public first, at most 8. A machine with an address another device could reach it by
always tells one: where nothing is left after all that, it tells the addresses of the interface its route goes by,
whatever kind that is, and with no route known, any interface's. (A virtual machine's own network card is its way
out, not a switch: Windows run by Hyper-V, as every Azure machine is, calls it "Microsoft Hyper-V Network Adapter",
where a host's switches are "vEthernet (…)", "Hyper-V Virtual Ethernet Adapter".) Where a node can be found nowhere
three seconds after it came up (no address another device could reach it by, and no link helper it is on), it says
so, as a `WHEREABOUTS` with neither, rather than nothing.

What iroh tells a node it links with as the link comes up (the addresses hole punching tries) is iroh's own list,
not this one; on the machines this was tried on it held the same network's addresses and no others.

### The port

A node asks for the same UDP port every time it starts on the same network, for IPv4 and IPv6 alike, so that where a
device was last said to be is still where it is after a stop and a start, and after the app was closed and opened
again there; and for another on every other network, so that the port does not follow the device from network to
network for anyone to know it by. A network is told apart by the networks of the interface the route to the internet
goes by (its IPv4 network and length, its IPv6 /64s); where that cannot be told, every such network is one.

The first time on a network, it asks for the port its node key makes for that network (49152 to 65535: two bytes of
a signature over words that are signed for nothing else and name the network, and that is shown to nobody, so the
port is no one else's to work out from the node id); every time after, for the port it had there (16 networks are
remembered). A port that is taken is not waited for, but for a second where it was this node's own a moment ago:
the node starts on any other, which is then its port on that network. A `helpers_only` node has no port.

What that gives away: on any one network, the same device shows the same local port each time, to whoever on that
network watches (behind a router, what the outside sees is the router's choice), and a device that knew it there
(a removed friend, say) can find the port again there. Starting on any port instead is one line (`first_port` in
`src/node.rs`).

## The C interface

Seven functions. Every one may be called from any thread, none waits on the network, and each catches a panic
(`-6`, or nothing happens) so a bug here cannot take the app down.

| Function | What it does |
| --- | --- |
| `uint32_t ghost_p2p_abi(void)` | The interface's number, `2`. A caller that finds another number uses nothing. Raised whenever a function, a command, an event or what one means changes. |
| `int32_t ghost_p2p_ready(void)` | `1` where this copy of the library has what it needs of the system to make a node: on Android, the app's context (below); elsewhere always. |
| `int32_t ghost_p2p_node_id(const uint8_t *secret, uint8_t *out)` | The node id (32 bytes, into `out`) that a node key (32 bytes) makes, with nothing started. `0`, or `-2` where either is null. |
| `uint64_t ghost_p2p_new(int64_t port, ghost_p2p_post_cb post, int64_t dart_api_major)` | Makes a node, not started, whose events are posted to the Dart port `port` through `post` (the Dart VM's `Dart_PostCObject`: `NativeApi.postCObject`). `dart_api_major` is `NativeApi.majorVersion`; another than `2` lays messages out otherwise, and no node is made. Answers its number, or `0`. |
| `int32_t ghost_p2p_command(uint64_t node, const uint8_t *command, size_t len)` | Gives the node a command (below). The bytes are read before it returns and not kept. |
| `void ghost_p2p_drop(uint64_t node)` | Stops the node and forgets it. Once this has returned nothing more of it is posted; its links and sockets close in the background. |
| `void ghost_p2p_finalize(void *token)` | `ghost_p2p_drop`, with the node's number as the token: what the Dart side attaches to each node with a `NativeFinalizer`. |

    typedef bool (*ghost_p2p_post_cb)(int64_t port, void *message);

**Events are messages, never calls.** A node's events are posted to its port in batches, in order: each message is a
list, the node's number first, then each event's bytes (below), and after a FRAME event's bytes, the frame's own
bytes (so the receiver hands a listener a list of its own). The VM copies everything as it is posted. A batch holds
whatever has come by the time the last was posted, up to 256 events or 2 MiB of frames, and batches are posted no
closer together than 2 ms (an event after a quiet while goes at once), so a flood of frames is a few hundred messages
a second to the app's thread, not one for each frame.

**Who made a node is its port.** Each Dart isolate has its own port, so one isolate's nodes are nothing to another's.
When an isolate ends, its port closes: the next post to it fails (harmlessly: that is what posting to a closed port
does), and the library lets go of every node made for that port. Because a node with nothing to say would never find
that out, the Dart side also attaches a native finalizer to each node, which the VM runs as the isolate ends (a hot
restart, an isolate that exits, a test that forgets to let go): the node is stopped then, sockets and all.

`ghost_p2p_command` answers:

| | |
| --- | --- |
| `0` | Taken. What it comes to is said in events. |
| `-1` | There is no such node. |
| `-2` | The command could not be read. |
| `-3` | `SEND`: there is no such stream (it has closed). |
| `-4` | `SEND`: the stream's queue was full. The stream is now closed. |
| `-5` | `SEND`: the frame is longer than 1 MiB. |
| `-6` | A bug in the library was caught. |

On Android there is one more, for Kotlin (`P2pCore.kt`): `Java_com_infamousvague_ghostmessaging_P2pCore_nativeInstall`
hands iroh's DNS the app's context, which it reads the phone's DNS servers through. Nothing calls it at the app's
start: when Dart first starts a node, it asks Kotlin over the channel `ghost_messaging/p2p`, which loads the library
through Java and calls it. The library is named (`DT_SONAME libghost_p2p.so`), so the system loads one copy whether
Kotlin or Dart opens it first, and Dart asks `ghost_p2p_ready` of its own copy before it makes a node. Loading the
library runs none of its code (it has no initialiser: `tool/build-p2p.sh` checks), so a person who never starts a
node runs nothing of it.

## Commands

Every number is big-endian. A node id is its 32 bytes. Text is UTF-8. The first byte says which command it is.

| | Command | After the first byte |
| --- | --- | --- |
| `01` | START | `[helpers only: 1][node key: 32][how many helpers: 1]`, then for each `[length: 2][address]`. At most 8 helpers, each `https://…` and at most 200 bytes. Answered by UP or DOWN. Up already with the same: UP again, nothing else. Up with another: stopped (OFF), then started. The node key is written over once it has been read, and the library keeps no copy of it but iroh's, while the node is up. |
| `02` | STOP | Nothing. Every stream closes, every linked node is told, the sockets close; then OFF. Who was allowed is kept. |
| `03` | ALLOW | `[node: 32][how many: 1][channel: 1]…` The channels this node may open streams on, in place of what it had; none takes it off the list. Streams it opened on a channel it no longer has are closed. |
| `04` | DISALLOW | `[node: 32]` Off the list, and every link and stream with it is closed. |
| `05` | OPEN_TO_ALL | `[how many: 1][channel: 1]…` The channels anyone may open, in place of what was. |
| `06` | OPEN | `[request: 4][node: 32][channel: 1][wait, ms: 4][helper length: 2][helper][how many addresses: 1]`, then for each `[length: 1][address]`. At most 8 addresses (`ip:port`), 64 bytes each. Answered by OPENED or OPEN_FAILED naming `request`. The wait is kept between 100 ms and 60 s. |
| `07` | SEND | `[stream: 8][the frame]` The frame is the rest of the command, 0 to 1 MiB. Queued; SENT says when it is written. |
| `08` | CLOSE | `[stream: 8]` What was queued before is written first, for 10 seconds at most; then the other end sees the end. CLOSED says when. |
| `09` | TAKEN | `[how many: 2]`, then for each `[stream: 8][frames: 4][bytes: 4]`: the app has handed that many frames of that stream, of that many bytes in all, to whoever listens. 1 to 4096 streams. See "What is counted". |
| `0a` | DONE | `[how many: 2]`, then for each `[stream: 8]`: the app has handled those streams' CLOSED. 1 to 4096 streams. |
| `0b` | NETWORK_CHANGED | Nothing. The device's network changed; Android does not tell native code by itself. |

ALLOW, DISALLOW and OPEN_TO_ALL are in force when `ghost_p2p_command` returns (a caller or a stream that comes after
is judged by them; what they close is closed a moment later, and the Dart side ends those streams at once, as far as
the app can see). They are kept by the node whether it is up or not, and across a STOP and a START.

## Events

| | Event | After the first byte |
| --- | --- | --- |
| `01` | UP | `[node id: 32]` |
| `02` | DOWN | `[why, in words]` It could not start (or stopped by a bug in the library, which then ends what was running as a stop would, and answers any later START with DOWN). |
| `03` | OFF | Nothing. Stopped: nothing of the node is left. No event of the run before comes after it. |
| `04` | WHEREABOUTS | `[helper length: 2][helper][how many: 1]`, then for each `[length: 1][address]`. Where this node is (see "What it tells others of where it is"): the helper it is on, written as START wrote it, and its addresses, public ones first, at most 8. Said when it changes, no more than once a second. |
| `05` | PATH | `[node: 32][kind: 1][round trip, ms: 4]` kind `0` no link, `1` through a helper, `2` straight. `ffffffff` where no round trip is measured. Said when the kind changes, or the round trip by more than a quarter (and 10 ms). Not said of a node let in only by a channel open to all. |
| `06` | OPENED | `[request: 4][stream: 8]` |
| `07` | OPEN_FAILED | `[request: 4][why: 1][in words]` |
| `08` | INCOMING | `[stream: 8][node: 32][channel: 1]` Another node opened a stream, on a channel it is allowed. |
| `09` | FRAME | `[stream: 8]`, and the frame's own bytes after it in the message. |
| `0a` | SENT | `[stream: 8][frames: 8]` How many of the stream's frames have been written, in all. |
| `0b` | CLOSED | `[stream: 8][why: 1]` |

OPEN_FAILED says why: `1` this node is not up, `2` it could not be reached in time, `3` it turned this node away (it
has not allowed it), `4` it is allowed but not on that channel, `5` what was asked makes no sense, `6` the link
already carries as many of this node's streams as a link does.

CLOSED says why: `0` closed here, `1` closed by the other end, `2` the link was lost, `3` this node stopped, `4` the
other node is no longer allowed, `5` the queue overflowed, `6` what came was no frame.

## A stream on the wire

One protocol, `ghost/1` (the ALPN). A stream is a QUIC bidirectional stream.

    opener    [channel: 1]
    taker     [01]                                   once it has checked the channel; otherwise it resets the stream
    both      [length: 4, big-endian][bytes] …       frames, each at most 1 MiB

`OPENED` is said only once the other end has answered, so a stream the app holds is one the other end took.

Closing is by either end and for both directions. The end that closes writes what it had queued, ends its half, and
waits (5 seconds at most) for the other end to have seen the end, which the other end shows by resetting its own
half: so a frame sent just before a close, or a close just before a stop, is not lost to what comes after. The
other end is handed every frame sent before the end, then CLOSED. What it had queued is given 10 seconds to be
written: past that the stream is reset, and what was still queued, or written and not yet arrived, is lost.

What SENT says, and so what a completed `add` means in Dart: the frame has been written to the link (QUIC has it, and
will send it and send it again until it is acknowledged), not that the other device has it or has read it. A frame
SENT can still be lost with the link.

### A path that is held back

A link helper holds back a device that sends faster than the helper allows, it does not drop: through one, round
trips rise to seconds and bytes leave at the helper's pace. A stream then does what it does whenever the other end
is slow. Its writer waits on QUIC, the frames given to SEND wait in the stream's queue, and SENT says how many have
been written, which is what a sender that wants to be held back goes by (in Dart, the future `add` returns). A
sender that goes on regardless fills the queue (4 MiB or 4096 frames): that SEND is answered `-4`, the stream is
closed (CLOSED `5`; the other end sees it closed by this one, CLOSED `1`), and what was queued is dropped. Only
that stream: the link and its other streams go on. Reading is not hurried by any of this, except that a frame
whose length has been said has 10 seconds and 32 KiB a second to arrive (see "What is counted").

A link (one QUIC connection) is closed 30 seconds after its last stream: an open link costs both devices a packet
every few seconds. The next OPEN dials again.

## Who is let in

1. A caller that comes **through a link helper** is known before any handshake (the helper says who is calling). Not
   allowed, and with no channel open to all, it is refused there.
2. Any other caller is held by QUIC's early handle until the handshake has said who it is (three seconds at most:
   the handshake as a whole has ten), and is closed on there if it is not allowed, before iroh has taken the link
   for its own (which is when iroh would tell it this node's addresses).
3. A caller that is allowed by name is handed to iroh; iroh's own hook (`after_handshake`) looks once more, and
   counts links (256 incoming at most).
4. A caller let in **only because a channel is open to all** is never handed to iroh: its link is carried on the
   connection the handshake left. So iroh sends it no list of this node's addresses, follows no path to it and
   keeps nothing of it; its link keeps QUIC's smaller window (128 KiB), which is counted against the budget while it
   is up (no more than 128 such links, half the budget); it is never used for a stream of this node's own; and no
   PATH is said of it.
5. Every stream's channel is checked as it is opened, and again when who is allowed changes; a link takes no more
   than 32 streams opened by the other node at once and 2 a second after, and turns back the rest unread.

A link this node dialled is one it chose; streams the other node opens on it are still checked (5).

### The door

So that callers this node does not let in cannot hold its door shut for those it does:

| | |
| --- | --- |
| Handshakes under way with callers straight to this node's address, and with strangers through a link helper | 64 |
| Of those, from one address (one `/64` for IPv6), or one node through a helper | 4 |
| Handshakes under way with callers through a link helper that this node let in by name: places of their own | 32, 2 for any one node |
| How long a caller has to say who it is | 3 seconds; then the rest of the handshake, up to 10 in all |
| When a caller straight to the address must first show it is where it says (QUIC's retry, before anything is set aside for it; a caller that cannot be answered there never gets past it) | once 32 handshakes are under way |
| A caller turned away 8 times in 10 seconds | not answered for the rest of the 10 seconds: no handshake's arithmetic is done for it |

What this does not give: a caller with many addresses still fills the pool for others straight to the address
(though not the places of those let in by name who come through a helper), and one behind the same address as a
friend shares that address's four places with them.

### What a node that links can learn

Not nothing, and it is iroh's to close, not this library's. QUIC's hole punching, inside iroh, lets the other end of a
link name addresses of its own as soon as its handshake is done, and answers each with a small probe (35 bytes)
before the app has any say. A probe shows where it came from. So any node that completes a handshake with this one
learns which address this node sends from towards each address it names: its address on a network they share, its
IPv6 address where it knew the IPv4 one, or, across the internet, the address its router shows.

- A caller that is **turned away** can do this only in the moment before it is closed on, and only if it already knows
  an address and port this node is reachable at straight (it cannot come through a link helper: see 1).
  `cargo test how_often -- --ignored --nocapture` measures it between two nodes on one machine (0 to 11 of 300 to
  600 callers, by run).
- A caller let in **only because a channel is open to all** can do it for as long as its link lasts, whether it came
  straight or through a helper: what it is not given is the list of this node's addresses (see 4). iroh 1.5 has no
  switch for hole punching on one connection and not another, so a node that must show strangers nothing at all (a
  relay hosted from the app, say) goes only through link helpers (`helpers_only`), with no socket of its own to send
  a probe from.

A node started with `helpers_only` has no socket to probe from at all.

### What a node that links can make this one send

The same probes go wherever the other end says it is, and nothing here can look at those addresses first (the review
of 2026-11-23). A node that links with this one, by name or turned away in the moment before it is closed on, can
name this machine's loopback, or another service on its network, as an address of its own, and this node sends a
small QUIC probe there (35 bytes, sealed, of nothing the other end chooses), a few times over. iroh 1.5 has no hook
for it: noq's hole punching (`n0_nat_traversal`, REACH_OUT on the dialled end, ADD_ADDRESS on the dialling end)
takes any address it is told; iroh's transport builder will not turn hole punching off, for the endpoint or for one
connection (`max_remote_nat_traversal_addresses` under 8 and `max_concurrent_multipath_paths` under 9 are ignored, and
`Incoming::accept_with` and `ConnectOptions` take only such a config); and its socket sends every IP destination it
is handed. `dialable` (src/node.rs) covers the addresses of a hint, and only those. What closes it is a patched noq (two calls in
`n0_nat_traversal.rs` that pass each address through the same check) or an iroh that offers a filter.
`cargo test named_probe -- --ignored` shows it, and passes the day it is closed. A node started with `helpers_only`
sends no probe at all.

## What is counted

So that no other device, however it behaves, makes this one hold more than it chose to:

| | |
| --- | --- |
| A frame | 1 MiB at most |
| Streams another node has open at once, on one link | 7 |
| Streams another node may open on one link | 32 at once, then 2 a second |
| What QUIC lets another node send unread | 256 KiB a stream; 128 KiB a link at first, 1 MiB once it is known to be a node let in by name or one this node dialled |
| A stream's queue of frames to send | 4 MiB or 4096 frames; past either the stream is closed (`-4`, CLOSED `5`) |
| What a stream has read that the app has not taken | 1 MiB + 64 KiB |
| What one other node has read, over all its streams and links, that the app has not taken | 3 MiB (its share) |
| What the whole node has read that the app has not taken | 32 MiB |
| A link with a node let in only by a channel open to all | 128 KiB of that budget while it is up, 128 such links at most |
| Frames one stream hands the app | 1000 a second (and 1000 at once) |
| How long a frame whose length was said has for its bytes | 10 seconds, and a second for every 32 KiB |
| Handshakes under way | see "The door" |
| Incoming links | 256, and one from any one node it let in by name (a node that links again replaces its earlier link) |

Every frame is counted from the moment its length is read (its bytes and 64 more) until the app says `TAKEN` for
it, against its stream's window, its sender's share and the node's one budget; an incoming stream counts 256 against
the share and the budget until the app says `DONE`. While there is no room nothing is read, and QUIC holds the
sender back. So the app must say `TAKEN` as it hands frames on (and may hold it back while whoever listens is
paused, which is how a slow reader slows the sender), and `DONE` when it has handled a stream's end. A frame whose
length was said and whose bytes do not come in time breaks the stream, so what was set aside is not held for a
sender that never sends.

What this does not give: fairness among many nodes. No one node holds more than its share (about a tenth of the
budget), but the eight devices of one friend can hold three quarters of it, and many nodes together all of it,
slowing the others until they are disallowed or their frames time out. Nothing they do grows it. QUIC's windows on
links with nodes let in by name are outside the budget: one link each, and the app lets in only its account's own
devices and its friends'.

## Building

    sh tool/build-p2p.sh mac        build/p2p/mac/libghost_p2p.dylib            both kinds of Mac in one file
    sh tool/build-p2p.sh android    build/p2p/android/arm64-v8a/libghost_p2p.so
    sh tool/build-p2p.sh ios        build/p2p/ios/GhostP2p.xcframework          a static library; not yet linked into the app
    cargo build --release           Windows (ghost_p2p.dll) and Linux (libghost_p2p.so), on their own runners

`Cargo.lock` is committed and every direct dependency is pinned to the version the tests ran against. Rust is
pinned too: 1.94.1, in `rust-toolchain.toml`, which rustup installs the first time; `tool/build-p2p.sh` stops on any
other and adds the targets it needs, and the Windows and Linux workflows install the same.

## Tests

    cargo test --release                            in native/p2p: the node, the bytes, the C interface
    cargo test cost -- --ignored --nocapture        what an idle node costs, measured over a minute
    flutter test test/p2p_node_ffi_test.dart        the same essentials from Dart, through the built library
    flutter test test/p2p_node_contract_test.dart   the built library held to what the route's stand-in is held to
    gh workflow run messaging-p2p-core.yml          cargo test on Linux and Windows

The Dart tests link nodes over this machine's own address on its network (a node dials no loopback address a hint
names), so the machine needs one. One Rust test listens on this machine's port 80 to see that a link helper's name
is never asked there. Where the machine gives a test no port 80 (Linux without root, or a server already on it),
that test has nothing to see and passes.
