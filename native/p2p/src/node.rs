//! The node: one device on the direct network (docs/OPEN_NETWORK.md, section 2; lib/net/p2p/node.dart is what the app
//! holds it by).
//!
//! It offers one thing: framed streams to another node by its id, on a numbered channel. A stream is a QUIC
//! bidirectional stream. Whoever opens it says the channel in its first byte; the other end answers one byte
//! ([`ACCEPTED`]) once it has checked that this node may have that channel, and from there both ends send frames of
//! `[length: 4 bytes, big-endian][bytes]`, at most [`MAX_FRAME`] bytes each.
//!
//! What it never does:
//! - look anyone up, or publish where it is: the endpoint is made with no address lookup at all, and its DNS (only
//!   ever asked for a link helper's name) asks the system's own servers and nobody else's;
//! - talk to a link helper the app did not name: a hint's helper is used only when it is one of this node's own; nor
//!   to anything else at a helper's name than the helper (iroh's captive-portal check, which asks port 80 there in
//!   plain HTTP, is off: [`probes`]);
//! - dial what a hint names that is no other device's address: this device's own (loopback), or one that means nothing
//!   off a link or everything at once (unspecified, link-local, multicast, broadcast), in whatever form an IPv6 address
//!   carries it ([`dialable`]), so a friend's hint cannot point this node at itself or at its network's services (QUIC's
//!   hole punching inside iroh still probes whatever address the other end of a link names: README.md, "What a node
//!   that links can make this one send");
//! - let a node that was not allowed say anything, or tell it anything: one that comes through a link helper is
//!   refused before any handshake (the helper says who is calling), and any other as soon as the handshake has said
//!   who it is, before iroh has taken the link for its own and told it this node's addresses;
//! - tell a node let in only because a channel is open to all where this one is: its link is never handed to iroh,
//!   which would send it every address this node has ([`Run::stranger`]);
//! - take early data (QUIC's 0-RTT, which can be replayed): a stream that opened in it is turned back unread;
//! - let callers it has not let in hold its door: handshakes are counted by where they come from, the caller has three
//!   seconds to say who it is, a caller whose address is not proved is asked to prove it once many are under way, and
//!   callers through a link helper that it let in by name have places of their own ([`Run::take_in`]);
//! - hold more than it was told to: every length from the other side is checked before it is believed, a frame's
//!   memory grows only as its bytes arrive and never past its length, a stream's queue of frames to send is bounded
//!   and closes the stream when it overflows, and everything read but not yet taken by the app is counted against a
//!   stream's window, a share for the node that sent it, and the node's one budget ([`NODE_BUDGET`]).

use std::{
    collections::{HashMap, HashSet},
    future::Future,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    sync::{
        Arc, Mutex, MutexGuard, RwLock, Weak,
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
    },
    time::Duration,
};

use iroh::{
    Endpoint, EndpointAddr, EndpointId, NetReportConfig, RelayConfig, RelayMap, RelayMode, RelayUrl, SecretKey, TransportAddr, Watcher,
    dns::DnsResolver,
    endpoint::{
        AcceptBi, AfterHandshakeOutcome, BindOpts, ConnectError, ConnectWithOptsError, ConnectingError, Connection, ConnectionError, EndpointHooks,
        Incoming, IncomingAddr, IncomingZeroRttConnection, OpenBi, PathList, QuicTransportConfig, ReadError, ReadExactError, RecvStream, SendStream,
        TransportErrorCode, VarInt, WriteError, presets,
    },
};
use n0_future::StreamExt;
use tokio::{
    runtime::Handle,
    sync::{Notify, OwnedSemaphorePermit, Semaphore, mpsc, watch},
    task::JoinSet,
    time::{Instant, timeout, timeout_at},
};
use tokio_util::sync::CancellationToken;

use crate::wire::{Channels, Closed, Command, Config, Event, FRAME_AT, Hint, MAX_ADDRESSES, MAX_FRAME, OpenError, PathKind};

/// The one protocol a node speaks. Another number is another protocol: a node of one never talks to the other.
pub const ALPN: &[u8] = b"ghost/1";

/// What the accepting end answers a stream's channel with.
const ACCEPTED: u8 = 1;

/// What a link or a stream is closed with, for the other end to read.
mod code {
    /// This node has not allowed the other.
    pub const NOT_ALLOWED: u32 = 1;
    /// The other is allowed, but not on that channel; or the stream opened in early data, which is never taken.
    pub const REFUSED: u32 = 2;
    /// The stream was closed.
    pub const CLOSED: u32 = 3;
    /// What came was no frame.
    pub const BROKEN: u32 = 4;
    /// The link carried no stream for [`super::LINK_IDLE`].
    pub const IDLE: u32 = 5;
    /// The other node linked again: its earlier link is let go.
    pub const REPLACED: u32 = 6;
    /// This node is stopping.
    pub const STOPPED: u32 = 7;
    /// This node has all the links it takes, or the other opened more streams in a while than a link may.
    pub const BUSY: u32 = 8;
    /// More was sent than the stream's queue holds.
    pub const OVERFLOW: u32 = 9;
}

/// The words this library says when it has stopped by a bug of its own.
const FELL: &str = "The direct network stopped by itself.";

/// How many streams the other node may have open to this one at once, on one link. Seven, not a rounder number: QUIC
/// (noq) tells the other end of a place that has come free only once more than an eighth of them are free, which
/// with fewer than eight is at once; with eight, the eighth place would wait for a second stream to end.
pub const STREAMS_PER_LINK: u32 = 7;
/// How many streams the other node may open on one link in a while: so many at once, then so many a second. Past
/// that a stream is turned back unread (each one the app hears of costs it a little, however short it lives).
const OPENS_AT_ONCE: f64 = 32.0;
const OPENS_PER_SECOND: f64 = 2.0;
/// QUIC's own windows: how much the other node may send on one stream, and on one link, that nothing here has read.
/// Every link starts with the smaller link window, and a stranger's keeps it (see [`STRANGER_LINK`]); a link with a
/// node this one let in by name, or dialled itself, is given the larger once it is up.
const STREAM_WINDOW: u32 = 256 * 1024;
const LINK_WINDOW_FIRST: u32 = 128 * 1024;
const LINK_WINDOW: u32 = 1024 * 1024;
/// How much this node sends on one link that the other has not yet acknowledged.
const SEND_WINDOW: u64 = 4 * 1024 * 1024;

/// A stream's queue of frames not yet written: past either, the stream is closed.
pub const SEND_QUEUE_BYTES: usize = 4 * 1024 * 1024;
pub const SEND_QUEUE_FRAMES: usize = 4096;
/// Every so many frames written, the app is told how far the writing has got; and whenever the queue is empty, and
/// whenever the next frame has not gone within a moment.
const SAY_SENT_EVERY: u64 = 64;
const SAY_SENT_WITHIN: Duration = Duration::from_millis(10);

/// What a stream may have read that the app has not taken: a frame of the most, and a little.
pub const TAKE_WINDOW: usize = MAX_FRAME + 64 * 1024;
/// What the whole node may have read that the app has not taken, whoever sent it.
pub const NODE_BUDGET: usize = 32 * 1024 * 1024;
/// What one other node may hold of that, over all its links and streams: a few frames of the most, so that no one
/// node holds more than a tenth of the budget, and a friend whose eight devices all fill theirs holds three quarters.
pub const PEER_SHARE: usize = 3 * 1024 * 1024;
/// What a frame costs of both, over its bytes (an empty frame is not free), and what an incoming stream costs until
/// the app has handled its end.
pub const FRAME_COST: usize = 64;
pub const STREAM_COST: usize = 256;
/// What a link with a node let in only because a channel is open to all costs of the budget while it is up: what QUIC
/// may hold for it unread. No more than [`MOST_STRANGER_LINKS`] of those at once, so they never take more than half.
const STRANGER_LINK: usize = LINK_WINDOW_FIRST as usize;
const MOST_STRANGER_LINKS: usize = NODE_BUDGET / 2 / STRANGER_LINK;
/// A frame's bytes are made room for this much at a time at first, as they come, and never past its length.
const READ_STEP: usize = 64 * 1024;
/// A frame whose length has been said is given this long, and its bytes no slower than this, before the stream is
/// taken to be broken: what was set aside for it is not held for a sender that never sends.
const FRAME_GRACE: Duration = Duration::from_secs(10);
const FRAME_SLOWEST: usize = 32 * 1024;
/// How many frames one stream hands the app a second, and at once: past that it is not read until it is time, and
/// QUIC holds the sender back. Each frame costs the app's own thread a little, however small it is.
const FRAMES_PER_SECOND: f64 = 1000.0;

/// Incoming links in all.
const MOST_INCOMING_LINKS: usize = 256;
/// A caller turned away more than so many times in so long is not answered until that while is over.
const REFUSALS_WINDOW: Duration = Duration::from_secs(10);
/// An incoming stream says its channel within this.
const CHANNEL_TIME: Duration = Duration::from_secs(10);
/// A link that carries no stream is closed after this: an open link costs both devices a packet every few seconds.
/// (The tests do not wait half a minute to see it.)
pub const LINK_IDLE: Duration = Duration::from_secs(if cfg!(test) { 4 } else { 30 });
/// A stream that was closed is given this long to write what was queued before it, and then this long for the other
/// end to see its end.
const CLOSE_FLUSH: Duration = Duration::from_secs(10);
const CLOSE_SEEN: Duration = Duration::from_secs(5);
/// What `open` waits at least and at most, whatever it was asked.
const OPEN_SHORTEST: Duration = Duration::from_millis(100);
const OPEN_LONGEST: Duration = Duration::from_secs(60);
/// The app hears where this node is no more often than this; and that it is nowhere (no address another device could
/// reach it by, no link helper it is on) once this long after it came up, where that is so.
const WHEREABOUTS_EVERY: Duration = Duration::from_secs(1);
const NOWHERE_AFTER: Duration = Duration::from_secs(3);
/// A link's round trip is looked at again this often, and a second after the link comes up.
const PATH_LOOK: Duration = Duration::from_secs(10);
/// A start asks for the port its node had before this many times, this far apart, before it takes any other: the
/// socket of a moment ago may still be closing.
const PORT_TRIES: u32 = 10;
const PORT_TRY_EVERY: Duration = Duration::from_millis(100);
/// How many networks a node remembers the port it had on.
const PORTS_KEPT: usize = 16;
/// A stopping node's own tasks are given this long to end before they are ended for it.
const TASKS_WAIT: Duration = Duration::from_secs(2);
/// The app is handed a node's events in batches of no more than so many, of no more than so many bytes of frames
/// (but always at least one event): whatever has come by the time it is free to be handed more. Batches are handed
/// no closer together than this, so a flood of frames is a few hundred messages a second to the app's thread and not
/// one for each frame; an event that comes after a quiet while goes at once.
const MOST_EVENTS_HANDED: usize = 256;
const MOST_BYTES_HANDED: usize = 2 * 1024 * 1024;
const HANDED_EVERY: Duration = Duration::from_millis(2);
/// The tests' nodes, all on one machine, dial each other's loopback addresses; a node outside them never dials one.
const LOOPBACK_DIALLED: bool = cfg!(test);

/// How many handshakes a node takes at once, from whom, and for how long. The same for every node but in the tests,
/// which look at each limit by making it small.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Limits {
    /// Handshakes under way at once with callers straight to this node's address, and with callers through a link
    /// helper that it let in only because a channel is open to all.
    pub handshakes: usize,
    /// Of those, how many from one address (one /64 for IPv6): a caller cannot take every place from one machine.
    pub per_source: usize,
    /// Handshakes under way at once with callers through a link helper that said who they are, and this node had let
    /// in by name: places of their own, that callers straight to the address cannot take.
    pub helper_handshakes: usize,
    /// Of those, how many with any one node.
    pub per_caller: usize,
    /// How long a caller has to say who it is, and the whole handshake has.
    pub identity: Duration,
    pub handshake: Duration,
    /// From how many handshakes under way a caller straight to the address that has not shown it is where it says it
    /// is (by answering what is sent there) is asked to, before anything is set aside for it.
    pub retry_from: usize,
    /// How many times a caller is turned away in [`REFUSALS_WINDOW`] before it is not answered for the rest of it.
    pub refusals: u32,
}

impl Limits {
    pub(crate) const USUAL: Limits = Limits {
        handshakes: 64,
        per_source: 4,
        helper_handshakes: 32,
        per_caller: 2,
        identity: Duration::from_secs(3),
        handshake: Duration::from_secs(10),
        retry_from: 32,
        refusals: 8,
    };
}

/// A lock that a panic elsewhere has not made useless.
fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Who may link with this node, and on which channels. Kept by the node across a stop and a start.
#[derive(Debug, Default)]
struct Admission {
    allowed: HashMap<EndpointId, Channels>,
    open: Channels,
}

impl Admission {
    /// Whether `node` was let in by name, on any channel.
    fn allowed(&self, node: &EndpointId) -> bool {
        self.allowed.get(node).is_some_and(|c| !c.is_empty())
    }

    /// Whether anyone at all may link, for a channel open to all.
    fn open_to_all(&self) -> bool {
        !self.open.is_empty()
    }

    /// Whether `node` may link at all.
    fn admits(&self, node: &EndpointId) -> bool {
        self.open_to_all() || self.allowed(node)
    }

    /// Whether `node` may open a stream on `channel`.
    fn permits(&self, node: &EndpointId, channel: u8) -> bool {
        self.open.has(channel) || self.allowed.get(node).is_some_and(|c| c.has(channel))
    }
}

/// The one list of who is allowed, shared by the node, its run and iroh's hook.
type Gatekeeper = Arc<RwLock<Admission>>;

/// The list to read, whatever a panic elsewhere did to its lock.
fn admission(gate: &Gatekeeper) -> std::sync::RwLockReadGuard<'_, Admission> {
    gate.read().unwrap_or_else(|p| p.into_inner())
}

/// iroh's own check as a handshake ends, for the links iroh is handed (with nodes let in by name, and the ones this
/// node dials): a second look at a caller [`Run::admit`] has already let through, and the count of links. It holds the
/// list and a count, never the endpoint (which holds it).
#[derive(Debug)]
struct Gate {
    admission: Gatekeeper,
    incoming: Arc<AtomicUsize>,
}

impl EndpointHooks for Gate {
    async fn after_handshake(&self, conn: &Connection) -> AfterHandshakeOutcome {
        // A link this node dialled is one it chose.
        if conn.side().is_client() {
            return AfterHandshakeOutcome::Accept;
        }
        if !admission(&self.admission).allowed(&conn.remote_id()) {
            return AfterHandshakeOutcome::Reject { error_code: VarInt::from_u32(code::NOT_ALLOWED), reason: b"not allowed".to_vec() };
        }
        if self.incoming.load(Ordering::Relaxed) >= MOST_INCOMING_LINKS {
            return AfterHandshakeOutcome::Reject { error_code: VarInt::from_u32(code::BUSY), reason: b"busy".to_vec() };
        }
        AfterHandshakeOutcome::Accept
    }
}

/// What lives as long as the node does.
struct Shared {
    events: mpsc::UnboundedSender<Event>,
    admission: Gatekeeper,
    /// The node while it is up, for what must not wait behind a start or a stop: sending, closing, taking.
    run: RwLock<Option<Arc<Run>>>,
    /// Streams are numbered by the node, never twice, across every start.
    next_stream: AtomicU64,
    /// The UDP port the node last had on each network it started on, for each node key it was started with: asked for
    /// again at its next start there with that key. Never another key's: two accounts signed in one after the other on
    /// one device would otherwise listen on one port, and whoever knew the first's address would know the second's.
    ports: Mutex<HashMap<([u8; 32], Vec<u8>), u16>>,
    /// How many times each node has been disallowed: an open asked before the last of them is not handed over, whatever
    /// its dial came to after ([`Run::open`]).
    let_go: Mutex<HashMap<EndpointId, u64>>,
    /// Its starting and stopping ended by a bug: whatever is asked of it is answered that it is down.
    fallen: AtomicBool,
}

impl Shared {
    /// Queues an event for the app; dropped where nothing is left to hand it over.
    fn say(&self, event: Event) {
        let _ = self.events.send(event);
    }

    /// The node as it is up now, or none.
    fn running(&self) -> Option<Arc<Run>> {
        self.run.read().unwrap_or_else(|p| p.into_inner()).clone()
    }

    /// How many times `node` has been disallowed so far.
    fn let_go_count(&self, node: &EndpointId) -> u64 {
        lock(&self.let_go).get(node).copied().unwrap_or(0)
    }
}

/// What the app asks that is done in order, one at a time. (Who is allowed is written down at once, where the app
/// asks it: only what follows from it waits its turn here.)
enum Act {
    Start(Config, Option<TestSetup>),
    Stop,
    /// Who is allowed has changed: what is open and no longer allowed is closed.
    Recheck,
    /// A node was disallowed: everything with it is closed.
    LetGo(EndpointId),
    Open {
        request: u32,
        node: [u8; 32],
        channel: u8,
        wait: Duration,
        hint: Hint,
        /// How many times the node had been disallowed when the open was asked.
        let_go: u64,
    },
    NetworkChanged,
    /// A bug, made on purpose: the tests' look at what is left of a node when its lifecycle ends by one.
    #[cfg(test)]
    Fall,
    End,
}

/// What a test starts a node with beside its config: a link helper inside the test's own process (its map, with the
/// port its address discovery listens on, and leave to trust its self-signed certificate), smaller limits, and the
/// network the node is on. There is no such thing outside the tests.
#[cfg(test)]
#[derive(Clone, Default)]
pub(crate) struct TestSetup {
    pub helper: Option<iroh::RelayMap>,
    pub limits: Option<Limits>,
    pub network: Option<Vec<u8>>,
}
#[cfg(not(test))]
pub(crate) type TestSetup = std::convert::Infallible;

/// Why a frame could not be queued.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SendError {
    /// No such stream: it has closed, or never was.
    NoStream,
    /// Longer than [`MAX_FRAME`].
    TooLong,
    /// The stream's queue was full: the stream is closed.
    Overflow,
}

/// A node, as the C interface and the tests hold it. It is off until it is started; dropping it stops it.
pub struct Node {
    shared: Arc<Shared>,
    acts: mpsc::UnboundedSender<Act>,
}

/// How much of a batch an event is, for [`MOST_BYTES_HANDED`].
fn weight(event: &Event) -> usize {
    match event {
        Event::Frame { frame, .. } => FRAME_AT + frame.len(),
        _ => 64,
    }
}

impl Node {
    /// A node whose tasks run on `on`, and whose events are given to `sink` in order, a batch at a time: whatever has
    /// come by the time the sink is free for more.
    pub fn new(on: &Handle, sink: impl Fn(Vec<Event>) + Send + 'static) -> Node {
        let (events, mut said) = mpsc::unbounded_channel::<Event>();
        let (acts, asked) = mpsc::unbounded_channel();
        let shared = Arc::new(Shared {
            events,
            admission: Gatekeeper::default(),
            run: RwLock::new(None),
            next_stream: AtomicU64::new(0),
            ports: Mutex::new(HashMap::new()),
            let_go: Mutex::new(HashMap::new()),
            fallen: AtomicBool::new(false),
        });
        on.spawn(async move {
            let mut handed: Option<Instant> = None;
            while let Some(first) = said.recv().await {
                if let Some(at) = handed {
                    tokio::time::sleep_until(at + HANDED_EVERY).await;
                }
                let mut bytes = weight(&first);
                let mut batch = vec![first];
                while batch.len() < MOST_EVENTS_HANDED && bytes < MOST_BYTES_HANDED {
                    let Ok(next) = said.try_recv() else { break };
                    bytes += weight(&next);
                    batch.push(next);
                }
                sink(batch);
                handed = Some(Instant::now());
            }
        });
        on.spawn(lifecycle(shared.clone(), asked, on.clone()));
        Node { shared, acts }
    }

    /// Gives the lifecycle `act`; false where there is no lifecycle to give it to (it ended by a bug).
    fn ask(&self, act: Act) -> bool {
        !self.shared.fallen.load(Ordering::Relaxed) && self.acts.send(act).is_ok()
    }

    /// Asks for the node to be up with `config`: the answer is an UP or a DOWN event. Up already with the same key
    /// and helpers, it only says UP again; with others, it is stopped first.
    pub fn start(&self, config: Config) {
        if !self.ask(Act::Start(config, None)) {
            self.shared.say(Event::Down { problem: FELL.into() });
        }
    }

    #[cfg(test)]
    pub(crate) fn start_with(&self, config: Config, setup: TestSetup) {
        if !self.ask(Act::Start(config, Some(setup))) {
            self.shared.say(Event::Down { problem: FELL.into() });
        }
    }

    /// Asks for the node to be stopped: the answer is an OFF event, whether or not it was up.
    pub fn stop(&self) {
        if !self.ask(Act::Stop) {
            self.shared.say(Event::Off);
        }
    }

    /// Lets `node` open streams on `channels`, in place of what it could before; none takes it off the list. In force
    /// when this returns: a caller or a stream that comes after it is judged by it. What it closes (streams on
    /// channels the node no longer has) is closed a moment later, in its turn.
    pub fn allow(&self, node: [u8; 32], channels: Channels) {
        let Ok(id) = EndpointId::from_bytes(&node) else { return };
        {
            let mut admission = self.shared.admission.write().unwrap_or_else(|p| p.into_inner());
            if channels.is_empty() {
                admission.allowed.remove(&id);
            } else {
                admission.allowed.insert(id, channels);
            }
        }
        self.ask(Act::Recheck);
    }

    /// Takes `node` off the list (in force when this returns) and closes every link and stream with it.
    pub fn disallow(&self, node: [u8; 32]) {
        let Ok(id) = EndpointId::from_bytes(&node) else { return };
        self.shared.admission.write().unwrap_or_else(|p| p.into_inner()).allowed.remove(&id);
        // Counted before the lifecycle hears of it: an open asked before this, whose dial is still under way, sees it
        // however its dial and this come out in time.
        *lock(&self.shared.let_go).entry(id).or_insert(0) += 1;
        self.ask(Act::LetGo(id));
    }

    /// The channels anyone at all may open, in place of what they were. In force when this returns.
    pub fn open_to_all(&self, channels: Channels) {
        self.shared.admission.write().unwrap_or_else(|p| p.into_inner()).open = channels;
        self.ask(Act::Recheck);
    }

    /// Answered with [`Event::Opened`] or [`Event::OpenFailed`], naming `request`.
    pub fn open(&self, request: u32, node: [u8; 32], channel: u8, wait: Duration, hint: Hint) {
        let let_go = EndpointId::from_bytes(&node).map(|id| self.shared.let_go_count(&id)).unwrap_or(0);
        if !self.ask(Act::Open { request, node, channel, wait, hint, let_go }) {
            self.shared.say(Event::OpenFailed { request, why: OpenError::NotUp, message: "The direct network is not up.".into() });
        }
    }

    /// The device's network changed (Wi-Fi for mobile data, say): iroh is told, so it looks at its paths again.
    pub fn network_changed(&self) {
        self.ask(Act::NetworkChanged);
    }

    /// The bug a test makes on purpose.
    #[cfg(test)]
    pub(crate) fn fall(&self) {
        self.ask(Act::Fall);
    }

    /// Queues a frame on a stream. It is written in its turn, and [`Event::Sent`] says when it has been.
    pub fn send(&self, stream: u64, frame: &[u8]) -> Result<(), SendError> {
        if frame.len() > MAX_FRAME {
            return Err(SendError::TooLong);
        }
        let st = self.shared.running().and_then(|run| lock(&run.streams).get(&stream).cloned()).ok_or(SendError::NoStream)?;
        let mut bytes = Vec::with_capacity(4 + frame.len());
        bytes.extend_from_slice(&(frame.len() as u32).to_be_bytes());
        bytes.extend_from_slice(frame);
        let mut queued = lock(&st.queued);
        if queued.closing {
            return Err(SendError::NoStream);
        }
        if queued.bytes + bytes.len() > SEND_QUEUE_BYTES || queued.frames >= SEND_QUEUE_FRAMES {
            queued.closing = true;
            drop(queued);
            st.stop_for(Closed::Overflow);
            return Err(SendError::Overflow);
        }
        queued.bytes += bytes.len();
        queued.frames += 1;
        st.out.send(Out::Frame(bytes)).map_err(|_| SendError::NoStream)
    }

    /// Closes a stream: what was queued before is written first (given [`CLOSE_FLUSH`] to be; what a slow path has
    /// not carried by then is given up, the stream reset), then the other end sees the end of it. [`Event::Closed`]
    /// says when. Closing what is closed is nothing.
    pub fn close(&self, stream: u64) {
        let Some(st) = self.shared.running().and_then(|run| lock(&run.streams).get(&stream).cloned()) else {
            return;
        };
        let mut queued = lock(&st.queued);
        if !queued.closing {
            queued.closing = true;
            let _ = st.out.send(Out::Finish);
            drop(queued);
            st.close_asked.notify_one();
        }
    }

    /// The app has handed `frames` frames of `bytes` bytes in all to whoever listens on a stream: that much more may
    /// be read for it.
    pub fn taken(&self, stream: u64, frames: u32, bytes: u32) {
        let Some(run) = self.shared.running() else { return };
        let credit = lock(&run.credits).get(&stream).cloned();
        if let Some(credit) = credit {
            run.give_back(&credit, (bytes as usize).saturating_add((frames as usize).saturating_mul(FRAME_COST)));
        }
    }

    /// The app has handled a stream's [`Event::Closed`]: whatever was still counted for it is let go.
    pub fn done(&self, stream: u64) {
        let Some(run) = self.shared.running() else { return };
        if lock(&run.streams).contains_key(&stream) {
            return;
        }
        let credit = lock(&run.credits).remove(&stream);
        if let Some(credit) = credit {
            let held = std::mem::take(&mut *lock(&credit.held));
            run.budget.add_permits(held + credit.stream);
            credit.share.add_permits(held + credit.stream);
        }
    }

    /// A command as the C interface is given it (src/wire.rs); what `ghost_p2p_command` answers.
    pub fn command(&self, bytes: &[u8]) -> i32 {
        use crate::wire::Malformed;
        let command = match Command::decode(bytes) {
            Ok(command) => command,
            Err(Malformed::TooLong) if bytes.first() == Some(&crate::wire::cmd::SEND) => return crate::ffi::TOO_LONG,
            Err(_) => return crate::ffi::MALFORMED,
        };
        match command {
            Command::Start(config) => self.start(config),
            Command::Stop => self.stop(),
            Command::Allow { node, channels } => self.allow(node, channels),
            Command::Disallow { node } => self.disallow(node),
            Command::OpenToAll { channels } => self.open_to_all(channels),
            Command::Open { request, node, channel, timeout, hint } => self.open(request, node, channel, timeout, hint),
            Command::Send { stream, .. } => {
                return match self.send(stream, &bytes[FRAME_AT..]) {
                    Ok(()) => crate::ffi::OK,
                    Err(SendError::NoStream) => crate::ffi::NO_STREAM,
                    Err(SendError::TooLong) => crate::ffi::TOO_LONG,
                    Err(SendError::Overflow) => crate::ffi::OVERFLOW,
                };
            }
            Command::Close { stream } => self.close(stream),
            Command::Taken { list } => {
                for (stream, frames, bytes) in list {
                    self.taken(stream, frames, bytes);
                }
            }
            Command::Done { list } => {
                for stream in list {
                    self.done(stream);
                }
            }
            Command::NetworkChanged => self.network_changed(),
        }
        crate::ffi::OK
    }

    /// How much of the node's budget is free, while it is up: the tests' own look at the counting.
    #[cfg(test)]
    pub(crate) fn budget_free(&self) -> Option<usize> {
        self.shared.running().map(|run| run.budget.available_permits())
    }

    /// How much of `peer`'s share is free, while this node is up (all of it where nothing of its is counted).
    #[cfg(test)]
    pub(crate) fn share_free(&self, peer: [u8; 32]) -> Option<usize> {
        let run = self.shared.running()?;
        let id = EndpointId::from_bytes(&peer).ok()?;
        Some(lock(&run.peers).get(&id).and_then(Weak::upgrade).map(|share| share.available_permits()).unwrap_or(PEER_SHARE))
    }

    /// How many handshakes are under way, in both pools.
    #[cfg(test)]
    pub(crate) fn handshaking(&self) -> Option<(usize, usize)> {
        let run = self.shared.running()?;
        Some((run.limits.handshakes - run.pools.any.available_permits(), run.limits.helper_handshakes - run.pools.helper.available_permits()))
    }

    /// What has crossed this node's sockets since it came up, as iroh counts it: bytes sent, bytes received, and
    /// datagrams received.
    #[cfg(test)]
    pub(crate) fn traffic(&self) -> Option<(u64, u64, u64)> {
        let run = self.shared.running()?;
        let m = &run.ep.metrics().socket;
        Some((
            m.send_ipv4.get() + m.send_ipv6.get() + m.send_relay.get(),
            m.recv_data_ipv4.get() + m.recv_data_ipv6.get() + m.recv_data_relay.get(),
            m.recv_datagrams.get(),
        ))
    }

    /// The sockets this node is bound to, while it is up.
    #[cfg(test)]
    pub(crate) fn sockets(&self) -> Vec<SocketAddr> {
        self.shared.running().map(|run| run.ep.bound_sockets()).unwrap_or_default()
    }

    /// What iroh knows of where `node` is, while this one is up.
    #[cfg(test)]
    pub(crate) async fn knows_of(&self, node: [u8; 32]) -> Vec<TransportAddr> {
        let Some(run) = self.shared.running() else { return Vec::new() };
        let Ok(id) = EndpointId::from_bytes(&node) else { return Vec::new() };
        run.ep.remote_info(id).await.map(|info| info.into_addrs().map(|a| a.into_addr()).collect()).unwrap_or_default()
    }
}

impl Drop for Node {
    fn drop(&mut self) {
        let _ = self.acts.send(Act::End);
    }
}

/// The node id a secret makes, with nothing started.
pub fn node_id(secret: &[u8; 32]) -> [u8; 32] {
    *SecretKey::from_bytes(secret).public().as_bytes()
}

/// What a running node was started with, as far as a second start with the same is to be told apart: never the node
/// key itself, which is not kept, but the id it makes.
#[derive(PartialEq, Eq)]
struct Started {
    node: [u8; 32],
    helpers: Vec<String>,
    helpers_only: bool,
}

impl Started {
    fn of(config: &Config) -> Started {
        Started { node: node_id(&config.secret), helpers: config.helpers.clone(), helpers_only: config.helpers_only }
    }
}

/// Starting, stopping and who is allowed: one thing at a time, in the order asked.
async fn lifecycle(shared: Arc<Shared>, mut asked: mpsc::UnboundedReceiver<Act>, on: Handle) {
    /// The run that is up, or being stopped, for [`Fell`].
    type Current = Arc<Mutex<Option<Arc<Run>>>>;
    /// Where this ever ends by a bug, it ends what was running as a stop would (its tasks, its links, its sockets), so
    /// nothing goes on taking callers that nobody hears of; says so; and from then on answers a start that it is down.
    struct Fell(Arc<Shared>, Current, Handle);
    impl Drop for Fell {
        fn drop(&mut self) {
            if !std::thread::panicking() {
                return;
            }
            self.0.fallen.store(true, Ordering::Relaxed);
            *self.0.run.write().unwrap_or_else(|p| p.into_inner()) = None;
            if let Some(run) = lock(&self.1).take() {
                run.stop.cancel();
                run.tasks.abort();
                self.2.spawn(run.shut());
            }
            self.0.say(Event::Down { problem: FELL.into() });
        }
    }
    let current: Current = Arc::default();
    let _fell = Fell(shared.clone(), current.clone(), on.clone());
    let mut run: Option<Arc<Run>> = None;
    let mut started_with: Option<Started> = None;
    while let Some(act) = asked.recv().await {
        match act {
            Act::Start(config, setup) => {
                let asked_for = Started::of(&config);
                if let Some(up) = &run {
                    if started_with.as_ref() == Some(&asked_for) {
                        shared.say(Event::Up { node: *up.id.as_bytes() });
                        continue;
                    }
                    end(&shared, &mut run, &current).await;
                    shared.say(Event::Off);
                }
                match Run::begin(&shared, &config, setup, &on).await {
                    Ok(up) => {
                        *lock(&current) = Some(up.clone());
                        *shared.run.write().unwrap_or_else(|p| p.into_inner()) = Some(up.clone());
                        shared.say(Event::Up { node: *up.id.as_bytes() });
                        up.go();
                        run = Some(up);
                        started_with = Some(asked_for);
                    }
                    Err(problem) => {
                        started_with = None;
                        shared.say(Event::Down { problem });
                    }
                }
                // The node key goes no further than here (iroh keeps its own copy while the node is up).
                drop(config);
            }
            Act::Stop => {
                end(&shared, &mut run, &current).await;
                started_with = None;
                shared.say(Event::Off);
            }
            Act::Recheck => {
                if let Some(up) = &run {
                    up.admission_changed();
                }
            }
            Act::LetGo(node) => {
                if let Some(up) = &run {
                    up.let_go(&node);
                }
            }
            Act::Open { request, node, channel, wait, hint, let_go } => match &run {
                Some(up) => up.tasks.spawn(up.clone().open(request, node, channel, wait, hint, let_go)),
                None => shared.say(Event::OpenFailed { request, why: OpenError::NotUp, message: "The direct network is not up.".into() }),
            },
            Act::NetworkChanged => {
                if let Some(up) = &run {
                    let ep = up.ep.clone();
                    up.tasks.spawn(async move { ep.network_change().await });
                }
            }
            #[cfg(test)]
            Act::Fall => panic!("a bug in the lifecycle, made by a test"),
            Act::End => break,
        }
    }
    end(&shared, &mut run, &current).await;
}

/// Stops the node where it is up. When this returns nothing of it is left: no task, no link, no socket.
async fn end(shared: &Arc<Shared>, run: &mut Option<Arc<Run>>, current: &Mutex<Option<Arc<Run>>>) {
    let Some(up) = run.take() else { return };
    *shared.run.write().unwrap_or_else(|p| p.into_inner()) = None;
    up.shut().await;
    *lock(current) = None;
}

/// What a stream's writer is handed.
enum Out {
    /// A frame with its length in front, as it goes on the wire.
    Frame(Vec<u8>),
    /// The stream was closed here: nothing after this.
    Finish,
}

/// What a stream's queue holds that is not yet written, counted against [`SEND_QUEUE_BYTES`] and
/// [`SEND_QUEUE_FRAMES`].
#[derive(Default)]
struct Queued {
    bytes: usize,
    frames: usize,
    /// Nothing more is taken: it was closed here, it overflowed, or it has ended.
    closing: bool,
}

/// What a stream has read that the app has not taken.
struct Credit {
    window: Semaphore,
    /// The share of the node at the other end, which every stream with it counts against.
    share: Arc<Semaphore>,
    /// What its frames have counted against the share and the node's budget, and not yet given back.
    held: Mutex<usize>,
    /// What the stream itself counts, given back only when the app has handled its end.
    stream: usize,
}

/// One stream while it is open, as the node's table holds it: what the app's send and close reach it by.
struct Stream {
    id: u64,
    peer: EndpointId,
    channel: u8,
    incoming: bool,
    /// To its writer, which sends on in order.
    out: mpsc::UnboundedSender<Out>,
    queued: Mutex<Queued>,
    /// The app closed it: from here its writer has [`CLOSE_FLUSH`] to write what was queued.
    close_asked: Notify,
    stop: CancellationToken,
    /// Why it was stopped, where something stopped it.
    why: Mutex<Option<Closed>>,
    credit: Arc<Credit>,
}

impl Stream {
    /// Stops it at once, without writing what is queued. The first reason given is the one that is said.
    fn stop_for(&self, why: Closed) {
        lock(&self.why).get_or_insert(why);
        self.stop.cancel();
    }
}

/// So many a second, and as many as `most` at once.
struct Bucket {
    rate: f64,
    most: f64,
    left: f64,
    at: Instant,
}

impl Bucket {
    fn new(rate: f64, most: f64) -> Bucket {
        Bucket { rate, most, left: most, at: Instant::now() }
    }

    /// Takes one where there is one; else says how long until there is.
    fn take(&mut self) -> Result<(), Duration> {
        let now = Instant::now();
        self.left = (self.left + now.duration_since(self.at).as_secs_f64() * self.rate).min(self.most);
        self.at = now;
        if self.left >= 1.0 {
            self.left -= 1.0;
            Ok(())
        } else {
            Err(Duration::from_secs_f64((1.0 - self.left) / self.rate))
        }
    }
}

/// A link's QUIC connection: as iroh holds it, or (for a node let in only because a channel is open to all) as the
/// handshake left it, never handed to iroh, which would tell the other end every address this node has.
enum LinkConn {
    Full(Connection),
    Early(IncomingZeroRttConnection),
}

impl LinkConn {
    fn close_reason(&self) -> Option<ConnectionError> {
        match self {
            LinkConn::Full(c) => c.close_reason(),
            LinkConn::Early(c) => c.close_reason(),
        }
    }

    fn close(&self, code: u32, reason: &[u8]) {
        match self {
            LinkConn::Full(c) => c.close(VarInt::from_u32(code), reason),
            LinkConn::Early(c) => c.close(VarInt::from_u32(code), reason),
        }
    }

    async fn closed(&self) -> ConnectionError {
        match self {
            LinkConn::Full(c) => c.closed().await,
            LinkConn::Early(c) => c.closed().await,
        }
    }

    fn accept_bi(&self) -> AcceptBi<'_> {
        match self {
            LinkConn::Full(c) => c.accept_bi(),
            LinkConn::Early(c) => c.accept_bi(),
        }
    }

    fn open_bi(&self) -> OpenBi<'_> {
        match self {
            LinkConn::Full(c) => c.open_bi(),
            LinkConn::Early(c) => c.open_bi(),
        }
    }

    fn set_receive_window(&self, window: u32) {
        match self {
            LinkConn::Full(c) => c.set_receive_window(VarInt::from_u32(window)),
            LinkConn::Early(c) => c.set_receive_window(VarInt::from_u32(window)),
        }
    }

    /// The connection where iroh holds it; none for a stranger's.
    fn full(&self) -> Option<&Connection> {
        match self {
            LinkConn::Full(c) => Some(c),
            LinkConn::Early(_) => None,
        }
    }
}

/// A link: one QUIC connection with another node, whichever of the two dialled.
struct Link {
    peer: EndpointId,
    conn: LinkConn,
    incoming: bool,
    /// Let in only because a channel is open to all: never told where this node is (iroh is not handed it), held to a
    /// small window counted against the budget, never used for a stream of this node's own, and no path said of it.
    stranger: bool,
    stop: CancellationToken,
    /// What the connection is closed with, and what its streams are told, where something ended it.
    ended: Mutex<Option<(u32, Closed)>>,
    /// How many streams it carries (or is setting up), and how many of them this node opened.
    streams: watch::Sender<usize>,
    ours: AtomicUsize,
    /// How its path stands, as last seen.
    path: Mutex<Option<(PathKind, Option<u32>)>>,
    /// The streams the other node may still open on it now.
    opens: Mutex<Bucket>,
}

impl Link {
    /// Ends the link, with the code its connection closes with and what its streams are told. The first reason
    /// given stands.
    fn end_with(&self, code: u32, why: Closed) {
        lock(&self.ended).get_or_insert((code, why));
        self.stop.cancel();
    }

    /// Neither ended here nor closed by the other end or the network.
    fn live(&self) -> bool {
        !self.stop.is_cancelled() && self.conn.close_reason().is_none()
    }

    /// Counts one more stream on the link (`ours`: one this node opened) until what is returned is dropped.
    fn carrying(self: &Arc<Self>, ours: bool) -> Carried {
        self.streams.send_modify(|n| *n += 1);
        if ours {
            self.ours.fetch_add(1, Ordering::Relaxed);
        }
        Carried { link: self.clone(), ours }
    }

    /// Done once it has carried nothing for [`LINK_IDLE`].
    async fn idle(&self) {
        let mut count = self.streams.subscribe();
        loop {
            if count.wait_for(|n| *n == 0).await.is_err() {
                return;
            }
            if timeout(LINK_IDLE, count.wait_for(|n| *n > 0)).await.is_err() {
                return;
            }
        }
    }
}

/// A stream that `open` has opened and the other end has taken: its link, its place on it, and its two halves.
type Opened = (Arc<Link>, Carried, SendStream, RecvStream);

/// A stream a link is counted as carrying, for as long as this is held.
struct Carried {
    link: Arc<Link>,
    ours: bool,
}

impl Drop for Carried {
    fn drop(&mut self) {
        if self.ours {
            self.link.ours.fetch_sub(1, Ordering::Relaxed);
        }
        self.link.streams.send_modify(|n| *n = n.saturating_sub(1));
    }
}

/// The node's own tasks, so a stop can wait for every one and end what does not end.
struct Tasks {
    set: Mutex<Option<JoinSet<()>>>,
    on: Handle,
}

impl Tasks {
    /// Starts a task, forgetting the ones that have ended; nothing is started once the node is stopping.
    fn spawn(&self, task: impl Future<Output = ()> + Send + 'static) {
        if let Some(set) = lock(&self.set).as_mut() {
            while set.try_join_next().is_some() {}
            set.spawn_on(task, &self.on);
        }
    }

    /// Waits `within` for every task to end, then ends the ones that have not; takes no more from then on.
    async fn end(&self, within: Duration) {
        let Some(mut set) = lock(&self.set).take() else { return };
        let ended = timeout(within, async { while set.join_next().await.is_some() {} }).await.is_ok();
        if !ended {
            set.abort_all();
            while set.join_next().await.is_some() {}
        }
    }

    /// Ends every task at once, and takes no more: what a lifecycle that fell by a bug does, as it cannot wait.
    fn abort(&self) {
        drop(lock(&self.set).take());
    }
}

/// Where a caller comes from, as its handshakes and refusals are counted: an address (IPv6 by its /64, the part a
/// network hands one household), or for a caller through a link helper, the node the helper says it is.
#[derive(Clone, Copy, Debug, Hash, PartialEq, Eq)]
enum Source {
    Net(IpAddr),
    Node(EndpointId),
}

impl Source {
    /// The source an address counts as: itself for IPv4 (and IPv4 carried in IPv6), its /64 for IPv6.
    fn of(ip: IpAddr) -> Source {
        match ip.to_canonical() {
            IpAddr::V6(v6) => {
                let s = v6.segments();
                Source::Net(IpAddr::V6(Ipv6Addr::new(s[0], s[1], s[2], s[3], 0, 0, 0, 0)))
            }
            v4 => Source::Net(v4),
        }
    }
}

/// The places handshakes take while they are under way: one pool for anyone, one for callers through a link helper
/// that this node let in by name, and in each no more than so many from one source.
struct Pools {
    any: Arc<Semaphore>,
    helper: Arc<Semaphore>,
    held: Arc<Mutex<HashMap<Source, usize>>>,
}

/// A place in a pool, given back when this is dropped.
struct Slot {
    _permit: OwnedSemaphorePermit,
    source: Source,
    held: Arc<Mutex<HashMap<Source, usize>>>,
}

impl Drop for Slot {
    fn drop(&mut self) {
        let mut held = lock(&self.held);
        if let Some(n) = held.get_mut(&self.source) {
            *n = n.saturating_sub(1);
            if *n == 0 {
                held.remove(&self.source);
            }
        }
    }
}

impl Pools {
    fn new(limits: &Limits) -> Pools {
        Pools { any: Arc::new(Semaphore::new(limits.handshakes)), helper: Arc::new(Semaphore::new(limits.helper_handshakes)), held: Arc::default() }
    }

    /// A place for one handshake, in the helper pool or the pool for anyone; none where the pool is full or `source`
    /// already has as many as one source may.
    fn take(&self, helper: bool, source: Source, limits: &Limits) -> Option<Slot> {
        let most = if helper { limits.per_caller } else { limits.per_source };
        let mut held = lock(&self.held);
        if held.get(&source).copied().unwrap_or(0) >= most {
            return None;
        }
        let permit = (if helper { &self.helper } else { &self.any }).clone().try_acquire_owned().ok()?;
        *held.entry(source).or_insert(0) += 1;
        Some(Slot { _permit: permit, source, held: self.held.clone() })
    }
}

/// Callers turned away, by where they came from: one turned away [`Limits::refusals`] times in [`REFUSALS_WINDOW`] is
/// not answered for the rest of it, so a handshake's arithmetic is not this node's to do for it without end.
#[derive(Default)]
struct Refusals(Mutex<HashMap<Source, (u32, Instant)>>);

impl Refusals {
    /// How many sources are remembered: past it the ones whose while is over are forgotten, and if that frees
    /// nothing, all of them.
    const MOST_KEPT: usize = 4096;

    /// Counts one more refusal of `source`, starting its count again where its while is over.
    fn note(&self, source: &Source) {
        let mut by = lock(&self.0);
        if by.len() >= Self::MOST_KEPT {
            by.retain(|_, (_, since)| since.elapsed() < REFUSALS_WINDOW);
            if by.len() >= Self::MOST_KEPT {
                by.clear();
            }
        }
        let seen = by.entry(*source).or_insert((0, Instant::now()));
        if seen.1.elapsed() >= REFUSALS_WINDOW {
            *seen = (0, Instant::now());
        }
        seen.0 += 1;
    }

    /// Whether `source` has been turned away `most` times in the window, and so is not answered now.
    fn resting(&self, source: &Source, most: u32) -> bool {
        lock(&self.0).get(source).is_some_and(|(n, since)| *n >= most && since.elapsed() < REFUSALS_WINDOW)
    }
}

/// What a handshake with a caller came to.
enum Admitted {
    /// A node this one let in by name: its link is iroh's, which tells it where this node is; and the streams it
    /// opened in the moment between the handshake's end and iroh's taking the link.
    Friend(Connection, Vec<(SendStream, RecvStream)>),
    /// A node let in only because a channel is open to all, and who it said it is.
    Stranger(IncomingZeroRttConnection, EndpointId),
}

/// The node while it is up: an endpoint, its links and their streams. A start makes one, a stop ends it.
struct Run {
    shared: Arc<Shared>,
    ep: Endpoint,
    id: EndpointId,
    /// The link helpers: as iroh holds each, and as the app wrote it.
    helpers: Vec<(RelayUrl, String)>,
    helpers_only: bool,
    limits: Limits,
    stop: CancellationToken,
    tasks: Tasks,
    links: Mutex<HashMap<EndpointId, Vec<Arc<Link>>>>,
    incoming_links: Arc<AtomicUsize>,
    stranger_links: AtomicUsize,
    /// One dial at a time to any one node.
    dialling: Mutex<HashMap<EndpointId, Arc<tokio::sync::Mutex<()>>>>,
    streams: Mutex<HashMap<u64, Arc<Stream>>>,
    /// Kept past a stream's end, until the app has handled it.
    credits: Mutex<HashMap<u64, Arc<Credit>>>,
    budget: Semaphore,
    /// Each other node's share of the budget, while anything of its is counted.
    peers: Mutex<HashMap<EndpointId, Weak<Semaphore>>>,
    pools: Pools,
    refusals: Refusals,
    /// How the path to each linked node was last said to stand.
    paths: Mutex<HashMap<EndpointId, (PathKind, Option<u32>)>>,
}

/// QUIC, bounded: the other node opens only streams of both directions and only so many, never sends a datagram, and
/// is acknowledged only so far ahead of what has been read.
fn transport() -> QuicTransportConfig {
    QuicTransportConfig::builder()
        .max_concurrent_bidi_streams(VarInt::from_u32(STREAMS_PER_LINK))
        .max_concurrent_uni_streams(VarInt::from_u32(0))
        .stream_receive_window(VarInt::from_u32(STREAM_WINDOW))
        .receive_window(VarInt::from_u32(LINK_WINDOW_FIRST))
        .send_window(SEND_WINDOW)
        .datagram_receive_buffer_size(None)
        .build()
}

/// A link helper as iroh is to hold it, made from the address the app wrote and from nothing else: its https address
/// whole (a port and a path are kept), no token, and for asking where this node is seen from, QUIC at the same name on
/// iroh's usual UDP port (7842, which a helper this app is given keeps to). The day a helper asks for a token it is
/// one more call here (`with_auth_token`), the token having come the way the address does.
pub(crate) fn helper(url: &RelayUrl) -> RelayConfig {
    RelayConfig::from(url.clone())
}

/// What iroh may ask to learn how this node is connected: only what a link helper is there to answer, at the address
/// the app wrote. The HTTPS probe stays (a GET of `ping` under the helper's own address: how a node with no socket of
/// its own comes by its helper at all). The captive-portal check does not: it asks
/// `http://<the helper's name>/generate_204`, in plain HTTP and on port 80 whatever the helper's own port, which is
/// a request to a server nobody named as a link helper; and where that server answers anything of its own, the node
/// is taken to be behind a captive portal for good.
fn probes() -> NetReportConfig {
    // Everything that can be left out is, and the one probe that is wanted is put back: so a check that a later iroh
    // adds is not on for having been forgotten here.
    let mut probes = NetReportConfig::minimal();
    probes.https_probes = true;
    probes
}

/// The UDP port a node asks for the first time it starts on a network: the same one for the same node key on the same
/// network, every time, so that where a device was last said to be is still where it is after the app was closed and
/// opened again there; and another on every other network, so that the port does not follow the device from one to
/// the next for anyone to know it by. Made of the key and not of the node id, so that it is nobody else's to work out:
/// two bytes of a signature over words that are signed for nothing else, and that is shown to nobody. Of the ports no
/// service is given (49152 to 65535).
pub(crate) fn first_port(secret: &[u8; 32], network: &[u8]) -> u16 {
    let words = [&b"ghost/1: the port this node asks for on "[..], network].concat();
    let made = SecretKey::from_bytes(secret).sign(&words).to_bytes();
    49152 + u16::from_be_bytes([made[0], made[1]]) % 16384
}

/// An address with the host part cleared, `prefix` bits kept.
fn masked(ip: IpAddr, prefix: u8) -> IpAddr {
    match ip {
        IpAddr::V4(v4) => {
            let keep = if prefix == 0 { 0 } else { u32::MAX << (32 - prefix.min(32) as u32) };
            IpAddr::V4(Ipv4Addr::from(u32::from(v4) & keep))
        }
        IpAddr::V6(v6) => {
            let keep = if prefix == 0 { 0 } else { u128::MAX << (128 - prefix.min(128) as u32) };
            IpAddr::V6(Ipv6Addr::from(u128::from(v6) & keep))
        }
    }
}

/// Whether an interface is a virtual machine's, a tunnel, or something else no other device reaches this one by: a
/// VPN's tunnel (utun, tun, tap, ppp, ipsec, WireGuard, Tailscale, ZeroTier), a bridge to virtual machines (Parallels,
/// VMware, VirtualBox, UTM, a Hyper-V host's switch, WSL, Docker, libvirt, LXC), Apple's own links between its devices
/// (AWDL, LLW), Android's Wi-Fi Direct and IPv4-over-IPv6 (CLAT) interfaces. Unix names by how they begin, Windows'
/// names and descriptions by the words in them. Not the network card a virtual machine itself is given ("Microsoft
/// Hyper-V Network Adapter" in a Windows machine run by Hyper-V, as every Azure one is): that is the machine's own way
/// out, and the only one it has.
pub(crate) fn virtual_interface(name: &str) -> bool {
    let name = name.to_ascii_lowercase();
    const BEGINS: &[&str] = &[
        "utun",
        "tun",
        "tap",
        "ppp",
        "ipsec",
        "wg",
        "zt",
        "tailscale",
        "bridge",
        "vmenet",
        "vmnet",
        "vnic",
        "feth",
        "vboxnet",
        "docker",
        "br-",
        "veth",
        "virbr",
        "lxc",
        "lxd",
        "cni",
        "flannel",
        "cali",
        "kube",
        "gif",
        "stf",
        "gre",
        "sit",
        "ip6tnl",
        "dummy",
        "awdl",
        "llw",
        "anpi",
        "p2p",
        "clat",
        "v4-",
        "nat64",
        "ham",
        "vpn",
    ];
    const HOLDS: &[&str] = &[
        "vethernet",
        "virtualbox",
        "vmware",
        "hyper-v virtual",
        "wsl",
        "tap-",
        "openvpn",
        "wireguard",
        "tailscale",
        "zerotier",
        "loopback",
        "bluetooth",
        "teredo",
        "isatap",
        "npcap",
        "vpn",
    ];
    BEGINS.iter().any(|b| name.starts_with(b)) || HOLDS.iter().any(|h| name.contains(h))
}

/// This machine's own addresses as a node judges what it tells others by: which interface each is on, and which
/// interface its route to the internet goes by.
#[derive(Clone, Debug, Default)]
pub(crate) struct Here {
    pub addrs: HashMap<IpAddr, Local>,
    pub default: Option<String>,
}

/// One of this machine's own addresses.
#[derive(Clone, Debug)]
pub(crate) struct Local {
    pub interface: String,
    /// The interface is a virtual machine's, a tunnel's, or another no other device reaches this one by.
    pub tunnel: bool,
    /// An IPv6 address the system means to change from time to time (a privacy address), told in place of a lasting one.
    pub temporary: bool,
    /// One the system no longer means to use, or has not yet seen to be its own.
    pub stale: bool,
    /// Its network: the address with the host part cleared, and how many bits are kept.
    pub network: (IpAddr, u8),
}

impl Here {
    /// This machine now: its interfaces as the system lists them (netdev: netlink on Linux and Android, getifaddrs on
    /// a Mac, the adapters' list on Windows; nothing is run in a process of its own), and which of them its route to
    /// the internet goes by ([`route_source`]).
    fn now() -> Here {
        let mut addrs = HashMap::new();
        for interface in netdev::get_interfaces().into_iter().filter(|i| i.is_up()) {
            let tunnel = tunnel_interface(
                &interface.name,
                interface.friendly_name.as_deref(),
                interface.description.as_deref(),
                interface.if_type == netdev::interface::types::InterfaceType::Tunnel,
            );
            for net in &interface.ipv4 {
                let ip = IpAddr::V4(net.addr());
                let network = (masked(ip, net.prefix_len()), net.prefix_len());
                addrs.insert(ip, Local { interface: interface.name.clone(), tunnel, temporary: false, stale: false, network });
            }
            for (at, net) in interface.ipv6.iter().enumerate() {
                let ip = IpAddr::V6(net.addr());
                let flags = interface.ipv6_addr_flags.get(at);
                let temporary = flags.is_some_and(|f| f.temporary);
                let stale = flags.is_some_and(|f| f.deprecated || f.tentative || f.duplicated);
                let network = (masked(ip, net.prefix_len()), net.prefix_len());
                addrs.insert(ip, Local { interface: interface.name.clone(), tunnel, temporary, stale, network });
            }
        }
        let default = route_source().and_then(|ip| addrs.get(&ip)).map(|local| local.interface.clone());
        Here { addrs, default }
    }

    /// What this machine is now, as a node sees it: the tests' look.
    #[cfg(test)]
    pub(crate) fn now_for_tests() -> Here {
        Here::now()
    }

    /// The interface this machine's route to the internet goes by, where it is one that leads somewhere: not a virtual
    /// machine's or a tunnel's (a VPN that takes the route leaves the network the device is really on to be told).
    fn route(&self) -> Option<&str> {
        let route = self.default.as_deref()?;
        let tunnel = self.addrs.values().any(|local| local.interface == route && local.tunnel) || virtual_interface(route);
        (!tunnel).then_some(route)
    }

    /// Which network this machine is on, for the port a node asks for there: the networks of the interface its route
    /// to the internet goes by (an IPv6 one by its /64, which a network hands a household for some time), each as
    /// address and length. Empty where that cannot be told: one port then for every such network.
    pub(crate) fn network(&self) -> Vec<u8> {
        let Some(route) = self.route() else { return Vec::new() };
        let mut nets: Vec<String> = self
            .addrs
            .iter()
            .filter(|(ip, local)| local.interface == route && !local.stale && rank(ip).is_some())
            .map(|(ip, local)| match ip {
                IpAddr::V4(_) => format!("{}/{}", local.network.0, local.network.1),
                IpAddr::V6(_) => format!("{}/64", masked(*ip, 64)),
            })
            .collect();
        nets.sort();
        nets.dedup();
        nets.join(",").into_bytes()
    }
}

/// Whether an interface, as the system describes it (its name; on Windows its friendly name and description too; and
/// whether the system calls it a tunnel), is one no other device reaches this one by ([`virtual_interface`]).
pub(crate) fn tunnel_interface(name: &str, friendly: Option<&str>, description: Option<&str>, tunnel_type: bool) -> bool {
    tunnel_type || virtual_interface(name) || friendly.is_some_and(virtual_interface) || description.is_some_and(virtual_interface)
}

/// The address this machine would send from towards the internet, as its routing table has it: a UDP socket is
/// pointed at an address of the ranges kept for documentation (192.0.2.1, 2001:db8::1), which sends nothing, and the
/// system says which of its addresses it would send from. IPv4's, or else IPv6's; none where there is no route.
fn route_source() -> Option<IpAddr> {
    fn from(bind: SocketAddr, to: SocketAddr) -> Option<IpAddr> {
        let socket = std::net::UdpSocket::bind(bind).ok()?;
        socket.connect(to).ok()?;
        Some(socket.local_addr().ok()?.ip()).filter(|ip| !ip.is_unspecified())
    }
    from((Ipv4Addr::UNSPECIFIED, 0).into(), (Ipv4Addr::new(192, 0, 2, 1), 9).into())
        .or_else(|| from((Ipv6Addr::UNSPECIFIED, 0).into(), (Ipv6Addr::new(0x2001, 0xdb8, 0, 0, 0, 0, 0, 1), 9).into()))
}

/// Which of this node's own addresses (as iroh found them) are worth telling another device, best first: where the
/// internet sees it (an address no interface here has, which a link helper said), and the addresses of the interface
/// its route to the internet goes by, which is the network it is on; where that is not known, or is a tunnel, those of
/// every interface but a virtual machine's or a tunnel's. Never one that means nothing off this device, nor a lasting
/// IPv6 address beside a privacy one, nor one the system no longer means to use; no more than the app keeps.
///
/// A machine with an address another device could reach it by always tells one: where nothing is left after that,
/// the addresses of the interface its route goes by, whatever kind it is; and where no route is known at all, those of
/// any interface. (A machine whose only way out looks like a virtual one, say a virtual machine whose network card is
/// named as a host's switches are, is better told by that address than not at all.)
pub(crate) fn worth_telling(found: impl Iterator<Item = SocketAddr>, here: &Here) -> Vec<SocketAddr> {
    let route = here.route();
    let private_on: HashSet<(&str, IpAddr)> =
        here.addrs.values().filter(|l| l.temporary && !l.stale).map(|l| (l.interface.as_str(), masked(l.network.0, 64))).collect();
    // Every address worth anything, each with where it is: on no interface here (where the internet sees this node), or
    // on one of this machine's interfaces.
    let mut found: Vec<(u8, SocketAddr, Option<&Local>)> = found
        .map(|a| SocketAddr::new(a.ip().to_canonical(), a.port()))
        .filter(|a| a.port() != 0)
        .filter_map(|a| Some((rank(&a.ip())?, a, here.addrs.get(&a.ip()))))
        .filter(|(_, a, local)| {
            local.is_none_or(|local| {
                let lasting_beside_private =
                    a.is_ipv6() && !local.temporary && private_on.contains(&(local.interface.as_str(), masked(local.network.0, 64)));
                !local.stale && !lasting_beside_private
            })
        })
        .collect();
    found.sort_by_key(|(rank, a, _)| (*rank, *a));
    found.dedup_by_key(|(_, a, _)| *a);
    // Which of this machine's own are told, the first of these that leaves any.
    let tiers: [&dyn Fn(&Local) -> bool; 3] = [
        &|local| match route {
            Some(route) => local.interface == route,
            None => !local.tunnel,
        },
        &|local| here.default.as_deref() == Some(local.interface.as_str()),
        &|_| here.default.is_none(),
    ];
    let own = tiers.iter().find(|tier| found.iter().any(|(_, _, local)| local.is_some_and(|l| tier(l)))).copied();
    found
        .into_iter()
        .filter(|(_, _, local)| match local {
            None => true,
            Some(local) => own.is_some_and(|tier| tier(local)),
        })
        .take(MAX_ADDRESSES)
        .map(|(_, a, _)| a)
        .collect()
}

/// Whether an address a hint names may be dialled: another device's address, and never this one's own (loopback, but
/// in the tests), nor one that means nothing off a link or everything at once (unspecified, "this network",
/// link-local, multicast, broadcast), in whichever form an IPv6 address carries an IPv4 one in (mapped, the old
/// compatible form, or the NAT64 prefix that a network's translator would send on to it).
pub(crate) fn dialable(addr: &SocketAddr, loopback: bool) -> bool {
    fn v4_ok(v4: Ipv4Addr, loopback: bool) -> bool {
        !(v4.is_unspecified()
            || v4.octets()[0] == 0
            || v4.is_link_local()
            || v4.is_multicast()
            || v4.is_broadcast()
            || (v4.is_loopback() && !loopback))
    }
    if addr.port() == 0 {
        return false;
    }
    match addr.ip() {
        IpAddr::V4(v4) => v4_ok(v4, loopback),
        IpAddr::V6(v6) => {
            let s = v6.segments();
            let carried = Ipv4Addr::from(u128::from(v6) as u32);
            if let Some(v4) = v6.to_ipv4_mapped() {
                v4_ok(v4, loopback)
            } else if v6.is_loopback() {
                loopback
            } else if s[..6] == [0; 6] {
                // The IPv4-compatible form (::a.b.c.d), long gone from use: nothing to dial, whatever it holds.
                false
            } else if s[..6] == [0x64, 0xff9b, 0, 0, 0, 0] {
                v4_ok(carried, loopback)
            } else {
                !(v6.is_unspecified() || v6.is_unicast_link_local() || v6.is_multicast())
            }
        }
    }
}

/// How long a frame of `len` bytes, whose length has been said, has for its bytes to come.
pub(crate) fn frame_time(len: usize) -> Duration {
    FRAME_GRACE + Duration::from_secs(len.div_ceil(FRAME_SLOWEST) as u64)
}

/// Makes room for `by` more bytes of a frame that is `most` long: doubling as it grows, so its bytes are copied no more
/// than about twice over, and never past `most`, so a frame holds no more memory than its length (which is what is
/// counted for it).
pub(crate) fn grow(frame: &mut Vec<u8>, by: usize, most: usize) {
    let want = frame.len() + by;
    if want > frame.capacity() {
        let room = (frame.capacity() * 2).max(want).min(most.max(want));
        frame.reserve_exact(room - frame.len());
    }
    frame.resize(want, 0);
}

impl Run {
    /// Brings a node up from `config`: reads its link helpers, binds the endpoint (on the port it last had on this
    /// network, where it can) and makes the run, taking no caller yet ([`Run::go`] does that). The error is the
    /// problem as the app is told it.
    async fn begin(shared: &Arc<Shared>, config: &Config, setup: Option<TestSetup>, on: &Handle) -> Result<Arc<Run>, String> {
        let mut helpers: Vec<(RelayUrl, String)> = Vec::new();
        for written in &config.helpers {
            if !written.starts_with("https://") {
                return Err(format!("A link helper's address begins https://, and this one does not: {written}"));
            }
            let url: RelayUrl = written.parse().map_err(|_| format!("This is not a link helper's address: {written}"))?;
            if !helpers.iter().any(|(known, _)| *known == url) {
                helpers.push((url, written.clone()));
            }
        }
        if config.helpers_only && helpers.is_empty() {
            return Err("Only through link helpers was chosen, and there is no link helper.".into());
        }
        #[cfg(test)]
        let (test_helper, limits, test_network) = match setup {
            Some(s) => (s.helper, s.limits.unwrap_or(Limits::USUAL), s.network),
            None => (None, Limits::USUAL, None),
        };
        #[cfg(not(test))]
        let limits = match setup {
            Some(never) => match never {},
            None => Limits::USUAL,
        };
        let incoming_links = Arc::new(AtomicUsize::new(0));
        // Made again for each port that is tried: binding uses it up.
        let make = |port: Option<u16>| -> Result<iroh::endpoint::Builder, String> {
            let mut builder = Endpoint::builder(presets::Minimal)
                .secret_key(SecretKey::from_bytes(&config.secret))
                .alpns(vec![ALPN.to_vec()])
                // Nobody is looked up and nothing is published: there is no address lookup to ask or to tell.
                .clear_address_lookup()
                .relay_mode(if helpers.is_empty() {
                    RelayMode::Disabled
                } else {
                    RelayMode::Custom(helpers.iter().map(|(url, _)| helper(url)).collect::<RelayMap>())
                })
                .net_report_config(probes())
                .transport_config(transport())
                // A link helper's name is asked of the system's own DNS servers and of no public one behind them.
                .dns_resolver(DnsResolver::builder().with_system_defaults().disable_fallback().build())
                .hooks(Gate { admission: shared.admission.clone(), incoming: incoming_links.clone() });
            #[cfg(test)]
            if let Some(map) = &test_helper {
                builder = builder.relay_mode(RelayMode::Custom(map.clone())).ca_tls_config(iroh::tls::CaTlsConfig::insecure_skip_verify());
            }
            if config.helpers_only {
                // No socket of this node's own at all: every packet goes through a link helper.
                builder = builder.clear_ip_transports();
            } else if let Some(port) = port {
                // The same port for both kinds of address. IPv4 must have it; where IPv6 cannot, the node goes
                // without IPv6 this once rather than give up the port.
                let unusable = |e| format!("The direct network could not start: {e:#}");
                builder = builder
                    .bind_addr((Ipv4Addr::UNSPECIFIED, port))
                    .map_err(unusable)?
                    .bind_addr_with_opts((Ipv6Addr::UNSPECIFIED, port), BindOpts::default().set_is_required(false))
                    .map_err(unusable)?;
            }
            Ok(builder)
        };
        // Which port: the one this node had before on this network, and else the one its key makes for this network,
        // so that the address another device was last told stays good across a stop and a start, and across the app
        // closing. A port that is taken is not waited for (but for a moment, where it was this node's own): any other
        // will do.
        let ep = if config.helpers_only {
            make(None)?.bind().await
        } else {
            let network = Here::now().network();
            #[cfg(test)]
            let network = test_network.clone().unwrap_or(network);
            let key = (node_id(&config.secret), network.clone());
            let had = lock(&shared.ports).get(&key).copied();
            let (port, mut tries) = match had {
                Some(port) => (port, PORT_TRIES),
                None => (first_port(&config.secret, &network), 1),
            };
            let ep = loop {
                match make(Some(port))?.bind().await {
                    Ok(ep) => break Ok(ep),
                    Err(_) if tries > 1 => {
                        tries -= 1;
                        tokio::time::sleep(PORT_TRY_EVERY).await;
                    }
                    Err(_) => break make(None)?.bind().await,
                }
            };
            if let Ok(ep) = &ep
                && let Some(port) = ep.bound_sockets().iter().find(|a| a.is_ipv4()).map(|a| a.port()).filter(|port| *port != 0)
            {
                let mut ports = lock(&shared.ports);
                if ports.len() >= PORTS_KEPT && !ports.contains_key(&key) {
                    ports.clear();
                }
                ports.insert(key, port);
            }
            ep
        }
        .map_err(|e| format!("The direct network could not start: {e:#}"))?;
        let run = Arc::new(Run {
            shared: shared.clone(),
            id: ep.id(),
            ep,
            helpers,
            helpers_only: config.helpers_only,
            limits,
            stop: CancellationToken::new(),
            tasks: Tasks { set: Mutex::new(Some(JoinSet::new())), on: on.clone() },
            links: Mutex::default(),
            incoming_links,
            stranger_links: AtomicUsize::new(0),
            dialling: Mutex::default(),
            streams: Mutex::default(),
            credits: Mutex::default(),
            budget: Semaphore::new(NODE_BUDGET),
            peers: Mutex::default(),
            pools: Pools::new(&limits),
            refusals: Refusals::default(),
            paths: Mutex::default(),
        });
        Ok(run)
    }

    /// Sets it going, once the app has been told it is up: taking callers, and saying where it is. (In that order,
    /// so that nothing a node says of itself comes before "up".)
    fn go(self: &Arc<Self>) {
        self.tasks.spawn(self.clone().serve());
        self.tasks.spawn(self.clone().tell_whereabouts());
    }

    /// Ends everything: the streams say so, every linked node is told, the sockets close.
    async fn shut(self: Arc<Self>) {
        // Each link is told why first, so that it closes with the code that says so; then everything is stopped.
        let links: Vec<Arc<Link>> = lock(&self.links).values().flatten().cloned().collect();
        for link in links {
            link.end_with(code::STOPPED, Closed::Stopped);
        }
        self.stop.cancel();
        // Tells every linked node and waits for it to have heard (a few seconds at the very most), then ends iroh's
        // own tasks. The sockets themselves close when the last holder of the endpoint goes, just below.
        self.ep.close().await;
        self.tasks.end(TASKS_WAIT).await;
        // What a task that had to be ended could not say for itself.
        let left: Vec<u64> = lock(&self.streams).drain().map(|(id, _)| id).collect();
        for stream in left {
            self.shared.say(Event::Closed { stream, why: Closed::Stopped });
        }
        let linked: Vec<EndpointId> = lock(&self.paths).drain().map(|(node, _)| node).collect();
        for node in linked {
            self.shared.say(Event::Path { node: *node.as_bytes(), kind: PathKind::None, rtt_ms: None });
        }
        lock(&self.links).clear();
    }

    /// Takes whoever calls.
    async fn serve(self: Arc<Self>) {
        loop {
            let incoming = tokio::select! {
                _ = self.stop.cancelled() => return,
                incoming = self.ep.accept() => incoming,
            };
            let Some(incoming) = incoming else { return };
            self.take_in(incoming);
        }
    }

    /// What is done with someone calling, before anything is set aside for them.
    ///
    /// Through a link helper, the helper says who is calling before any handshake: one that is not allowed, with no
    /// channel open to all, is refused there and learns nothing of this node at all; one let in by name takes a place
    /// in a pool of its own, which callers straight to this node's address cannot fill. Any other caller is counted by
    /// where it comes from (no more than [`Limits::per_source`] at once from one address, one /64 for IPv6), is asked to
    /// show that it is where it says it is once many handshakes are under way (QUIC's retry, which a caller that
    /// cannot be answered there never gets past, before anything is set aside for it), has three seconds to say who it
    /// is, and is not answered for a while once it has been turned away too often.
    fn take_in(self: &Arc<Self>, mut incoming: Incoming) {
        let (source, helper, direct) = match incoming.remote_addr() {
            IncomingAddr::Relay { endpoint_id, .. } => {
                let (allowed, open) = {
                    let a = admission(&self.shared.admission);
                    (a.allowed(&endpoint_id), a.open_to_all())
                };
                let source = Source::Node(endpoint_id);
                if !allowed && !open {
                    if self.refusals.resting(&source, self.limits.refusals) {
                        incoming.ignore();
                    } else {
                        self.refusals.note(&source);
                        incoming.refuse();
                    }
                    return;
                }
                (source, allowed, false)
            }
            IncomingAddr::Ip(addr) => (Source::of(addr.ip()), false, true),
            _ => return incoming.refuse(),
        };
        if self.refusals.resting(&source, self.limits.refusals) {
            return incoming.ignore();
        }
        if direct && self.limits.handshakes - self.pools.any.available_permits() >= self.limits.retry_from && !incoming.remote_addr_validated() {
            match incoming.retry() {
                Ok(()) => return,
                Err(not) => incoming = not.into_incoming(),
            }
        }
        let Some(slot) = self.pools.take(helper, source, &self.limits) else { return incoming.ignore() };
        let run = self.clone();
        self.tasks.spawn(async move {
            let admitted = tokio::select! {
                _ = run.stop.cancelled() => None,
                admitted = run.admit(incoming, source) => admitted,
            };
            drop(slot);
            match admitted {
                Some(Admitted::Friend(conn, before)) => {
                    let peer = conn.remote_id();
                    let link = run.linked(LinkConn::Full(conn), peer, true, false);
                    for (mut send, mut recv) in before {
                        if lock(&link.opens).take().is_err() {
                            turn_back(&mut send, &mut recv, code::BUSY);
                            continue;
                        }
                        run.tasks.spawn(run.clone().taken_in(link.clone(), send, recv));
                    }
                }
                Some(Admitted::Stranger(early, caller)) => run.stranger(early, caller),
                None => {}
            }
        });
    }

    /// The handshake with a caller, and who it turns out to be: a link where that node is allowed, nothing where it
    /// is not.
    ///
    /// The order matters. As soon as iroh takes a link for its own (which it does before it asks the gate) it tells
    /// the other end every address this node has, so that the two can find a straight path. So the caller is looked
    /// at before that: the connection is held by its early handle, which iroh has not yet taken, until the
    /// handshake has said who is calling, and a node that is not allowed is closed on there, never having been told
    /// that list. A node let in only because a channel is open to all is never handed to iroh at all. Nothing is read
    /// from or written to the early handle here (whatever a caller sent ahead of its handshake waits, within QUIC's
    /// windows, and a stream that opened in that early data is turned back unread).
    ///
    /// What this does not close (README.md, "What a caller that is turned away can still learn"): QUIC's hole
    /// punching answers a caller's own list of addresses with a small probe to each before anything here has a say,
    /// and a probe shows where it came from.
    async fn admit(&self, incoming: Incoming, source: Source) -> Option<Admitted> {
        let began = Instant::now();
        let early = incoming.accept().ok()?.into_0rtt();
        // iroh has nothing to wait on for "the handshake has said who it is", so it is looked for: after one
        // millisecond, then two, and so on to twenty; for no longer than a caller has to say it.
        let said = timeout(self.limits.identity, async {
            let mut pause = Duration::from_millis(1);
            loop {
                if early.peer_identity().is_some() {
                    return early.remote_id().ok();
                }
                tokio::select! {
                    _ = early.closed() => return None,
                    _ = tokio::time::sleep(pause) => {}
                }
                pause = (pause * 2).min(Duration::from_millis(20));
            }
        })
        .await;
        let caller = said.ok().flatten()?;
        let (allowed, open) = {
            let a = admission(&self.shared.admission);
            (a.allowed(&caller), a.open_to_all())
        };
        if allowed {
            // The rest of the handshake; then iroh takes the link, and the gate looks once more. A stream that comes
            // before the handshake has ended came in early data (QUIC's 0-RTT, which whoever saw it could send
            // again, and which iroh's TLS takes from a caller that holds a ticket of an earlier link): this node takes
            // early data from nobody, and closes the link for it.
            // (A stream that comes once the handshake has ended, in the moment before iroh has taken the link, is not
            // early data, and is carried with the link like any other.)
            let left = self.limits.handshake.saturating_sub(began.elapsed());
            let rest = async {
                let mut before = Vec::new();
                loop {
                    tokio::select! {
                        biased;
                        stream = early.accept_bi() => match stream {
                            Ok((_, recv)) if recv.is_0rtt() => {
                                early.close(VarInt::from_u32(code::REFUSED), b"no early data");
                                return None;
                            }
                            Ok(halves) => before.push(halves),
                            Err(_) => return None,
                        },
                        done = early.handshake_completed() => return done.ok().map(|conn| Admitted::Friend(conn, before)),
                    }
                }
            };
            return timeout(left, rest).await.ok().flatten();
        }
        if open {
            return Some(Admitted::Stranger(early, caller));
        }
        early.close(VarInt::from_u32(code::NOT_ALLOWED), b"not allowed");
        self.refusals.note(&source);
        None
    }

    /// A node let in only because a channel is open to all: linked on the connection the handshake left, which iroh
    /// is never handed (so nothing tells it where this node is), within a window of its own that the budget counts
    /// while it is up, and only while there are not already as many of those as the budget lets be.
    fn stranger(self: &Arc<Self>, early: IncomingZeroRttConnection, caller: EndpointId) {
        let busy = self.incoming_links.load(Ordering::Relaxed) >= MOST_INCOMING_LINKS
            || self.stranger_links.load(Ordering::Relaxed) >= MOST_STRANGER_LINKS
            || self.budget.try_acquire_many(STRANGER_LINK as u32).map(|held| held.forget()).is_err();
        if busy {
            early.close(VarInt::from_u32(code::BUSY), b"busy");
            return;
        }
        self.linked(LinkConn::Early(early), caller, true, true);
    }

    /// A link is up: it is listed, and a task carries it until it ends.
    fn linked(self: &Arc<Self>, conn: LinkConn, peer: EndpointId, incoming: bool, stranger: bool) -> Arc<Link> {
        if !stranger {
            // A node this one let in by name, or one it dialled itself: QUIC may hold as much for it as a link does.
            conn.set_receive_window(LINK_WINDOW);
        }
        let (streams, _) = watch::channel(0);
        let link = Arc::new(Link {
            peer,
            conn,
            incoming,
            stranger,
            stop: self.stop.child_token(),
            ended: Mutex::new(None),
            streams,
            ours: AtomicUsize::new(0),
            path: Mutex::new(None),
            opens: Mutex::new(Bucket::new(OPENS_PER_SECOND, OPENS_AT_ONCE)),
        });
        {
            let mut links = lock(&self.links);
            let list = links.entry(peer).or_default();
            if incoming && !stranger {
                // A node that links again has let its earlier link go (it dials only where it has none): so is it here.
                for earlier in list.iter().filter(|l| l.incoming) {
                    earlier.end_with(code::REPLACED, Closed::LinkLost);
                }
            }
            if incoming {
                self.incoming_links.fetch_add(1, Ordering::Relaxed);
            }
            if stranger {
                self.stranger_links.fetch_add(1, Ordering::Relaxed);
            }
            list.push(link.clone());
        }
        // Allowed when the handshake ended; and now?
        if incoming {
            let a = admission(&self.shared.admission);
            if !(if stranger { a.admits(&peer) } else { a.allowed(&peer) }) {
                link.end_with(code::NOT_ALLOWED, Closed::NotAllowed);
            }
        }
        self.tasks.spawn(self.clone().carry(link.clone()));
        link
    }

    /// Carries a link until it ends: takes the streams the other node opens, watches its path, lets it go when idle.
    async fn carry(self: Arc<Self>, link: Arc<Link>) {
        /// Whatever way this task ends, the link is closed and no longer listed.
        struct Ends(Arc<Run>, Arc<Link>);
        impl Drop for Ends {
            fn drop(&mut self) {
                let (run, link) = (&self.0, &self.1);
                // Closed here only where it is not closed already: closing it again would put "closed here" in
                // place of what the other end closed it with, which an open under way is about to read.
                if link.conn.close_reason().is_none() {
                    let code = (*lock(&link.ended)).map(|(code, _)| code).unwrap_or(code::CLOSED);
                    link.conn.close(code, b"");
                }
                link.stop.cancel();
                {
                    let mut links = lock(&run.links);
                    if let Some(list) = links.get_mut(&link.peer) {
                        list.retain(|l| !Arc::ptr_eq(l, link));
                        if list.is_empty() {
                            links.remove(&link.peer);
                        }
                    }
                }
                if link.incoming {
                    run.incoming_links.fetch_sub(1, Ordering::Relaxed);
                }
                if link.stranger {
                    run.stranger_links.fetch_sub(1, Ordering::Relaxed);
                    run.budget.add_permits(STRANGER_LINK);
                }
                run.say_path(&link.peer);
            }
        }
        let _ends = Ends(self.clone(), link.clone());
        let take = async {
            while let Ok((mut send, mut recv)) = link.conn.accept_bi().await {
                // More streams opened in a while than a link may open: turned back unread, and the app never hears.
                if lock(&link.opens).take().is_err() {
                    turn_back(&mut send, &mut recv, code::BUSY);
                    continue;
                }
                self.tasks.spawn(self.clone().taken_in(link.clone(), send, recv));
            }
        };
        // What follows the path never ends the link: iroh's word on a link's paths can end a moment before the link
        // itself is known to have, and closing it here in that moment would hide why the other end closed it.
        let watch = async {
            let Some(conn) = link.conn.full() else { return std::future::pending().await };
            loop {
                self.watch_path(&link, conn).await;
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
        };
        tokio::select! {
            _ = link.stop.cancelled() => {}
            _ = take => {}
            _ = link.conn.closed() => {}
            _ = watch => {}
            _ = link.idle() => link.end_with(code::IDLE, Closed::LinkLost),
        }
    }

    /// Follows a link's path for as long as the link is up.
    async fn watch_path(&self, link: &Link, conn: &Connection) {
        let mut changes = conn.paths_stream();
        let mut look = tokio::time::interval_at(Instant::now() + Duration::from_secs(1), PATH_LOOK);
        look.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            let seen = tokio::select! {
                changed = changes.next() => match changed {
                    Some(paths) => standing(&paths),
                    None => return,
                },
                _ = look.tick() => standing(&conn.paths()),
            };
            if let Some(seen) = seen {
                *lock(&link.path) = Some(seen);
                self.say_path(&link.peer);
            }
        }
    }

    /// Says how the path to `peer` stands, where that is not what was last said: straight if any of its links is,
    /// and none when the last link has gone. (Nothing is said of a stranger's link.)
    fn say_path(&self, peer: &EndpointId) {
        let now = {
            let links = lock(&self.links);
            let mut best: Option<(PathKind, Option<u32>)> = None;
            for link in links.get(peer).into_iter().flatten().filter(|l| l.live() && !l.stranger) {
                let Some(seen) = *lock(&link.path) else { continue };
                best = Some(match best {
                    None => seen,
                    Some(had)
                        if (seen.0 as u8, std::cmp::Reverse(seen.1.unwrap_or(u32::MAX)))
                            > (had.0 as u8, std::cmp::Reverse(had.1.unwrap_or(u32::MAX))) =>
                    {
                        seen
                    }
                    Some(had) => had,
                });
            }
            best
        };
        let mut said = lock(&self.paths);
        match (said.get(peer).copied(), now) {
            (None, None) => {}
            (Some(_), None) => {
                said.remove(peer);
                self.shared.say(Event::Path { node: *peer.as_bytes(), kind: PathKind::None, rtt_ms: None });
            }
            (before, Some(now)) => {
                let same = before.is_some_and(|before| before.0 == now.0 && close_enough(before.1, now.1));
                if !same {
                    said.insert(*peer, now);
                    self.shared.say(Event::Path { node: *peer.as_bytes(), kind: now.0, rtt_ms: now.1 });
                }
            }
        }
    }

    /// Each other node's share of the budget: one for as long as anything of its is counted.
    fn share(&self, peer: &EndpointId) -> Arc<Semaphore> {
        let mut peers = lock(&self.peers);
        if let Some(share) = peers.get(peer).and_then(Weak::upgrade) {
            return share;
        }
        peers.retain(|_, share| share.strong_count() > 0);
        let share = Arc::new(Semaphore::new(PEER_SHARE));
        peers.insert(*peer, Arc::downgrade(&share));
        share
    }

    /// The other node opened a stream: its first byte says the channel, and it is taken only where that is allowed.
    async fn taken_in(self: Arc<Self>, link: Arc<Link>, mut send: SendStream, mut recv: RecvStream) {
        let carried = link.carrying(false);
        // Opened in early data, before the handshake had ended (a stranger's streams are taken on the connection the
        // handshake left, while it may still be under way): never taken, and the link is closed for it.
        if recv.is_0rtt() {
            turn_back(&mut send, &mut recv, code::REFUSED);
            link.end_with(code::REFUSED, Closed::Broken);
            return;
        }
        let stop = link.stop.child_token();
        let mut first = [0u8; 1];
        let channel = tokio::select! {
            _ = stop.cancelled() => None,
            read = timeout(CHANNEL_TIME, recv.read_exact(&mut first)) => matches!(read, Ok(Ok(()))).then_some(first[0]),
        };
        let Some(channel) = channel else {
            turn_back(&mut send, &mut recv, code::BROKEN);
            return;
        };
        if !admission(&self.shared.admission).permits(&link.peer, channel) {
            turn_back(&mut send, &mut recv, code::REFUSED);
            return;
        }
        // What the stream itself costs, until the app has handled its end, of the other node's share and of the
        // budget: streams opened and closed faster than the app looks at them are not kept without bound either.
        let share = self.share(&link.peer);
        let paid = tokio::select! {
            _ = stop.cancelled() => false,
            paid = async {
                let Ok(of_share) = share.acquire_many(STREAM_COST as u32).await else { return false };
                let Ok(of_budget) = self.budget.acquire_many(STREAM_COST as u32).await else { return false };
                of_share.forget();
                of_budget.forget();
                true
            } => paid,
        };
        if !paid {
            turn_back(&mut send, &mut recv, code::STOPPED);
            return;
        }
        if send.write_all(&[ACCEPTED]).await.is_err() {
            self.budget.add_permits(STREAM_COST);
            share.add_permits(STREAM_COST);
            return;
        }
        let (st, queue) = self.listed(&link, channel, true, stop, STREAM_COST, share);
        self.shared.say(Event::Incoming { stream: st.id, node: *link.peer.as_bytes(), channel });
        // Allowed when it was asked; and now?
        if !admission(&self.shared.admission).permits(&link.peer, channel) {
            st.stop_for(Closed::NotAllowed);
        }
        self.pump(&link, st, send, recv, queue).await;
        drop(carried);
    }

    /// Opens a stream to `node` on `channel`, dialling where no link is up. Where the node was disallowed after the open
    /// was asked (`let_go` says how many times it had been then), nothing of it is handed over: a dial under way when
    /// DISALLOW came, which LetGo found no link of to close, ends in a link that is closed and an open that fails.
    async fn open(self: Arc<Self>, request: u32, node: [u8; 32], channel: u8, wait: Duration, hint: Hint, let_go: u64) {
        let fail = |why: OpenError, message: &str| self.shared.say(Event::OpenFailed { request, why, message: message.into() });
        let Ok(peer) = EndpointId::from_bytes(&node) else {
            return fail(OpenError::BadRequest, "That is not a node id.");
        };
        if peer == self.id {
            return fail(OpenError::BadRequest, "A node does not link with itself.");
        }
        // How far it got, for the answer where the wait runs out; and the link, where one that was up already was used.
        let reached = AtomicUsize::new(0);
        let used: Mutex<Option<Arc<Link>>> = Mutex::new(None);
        let attempt = async {
            let mut tried_again = false;
            loop {
                let (link, fresh) = self.link_to(peer, &hint, let_go).await?;
                *lock(&used) = (!fresh).then(|| link.clone());
                let carried = link.carrying(true);
                reached.store(1, Ordering::Relaxed);
                // A link that was up when it was taken and that this node itself closed in the same moment (it had
                // just been idle long enough, or the other node had just linked again) is no answer about the other
                // node: once, the open goes round again, and dials or takes the newer link.
                let gone = |e: &ConnectionError| !fresh && !tried_again && matches!(e, ConnectionError::LocallyClosed);
                let (mut send, mut recv) = match link.conn.open_bi().await {
                    Ok(halves) => halves,
                    Err(e) if gone(&e) => {
                        tried_again = true;
                        continue;
                    }
                    Err(e) => return Err(why_lost(&e)),
                };
                reached.store(2, Ordering::Relaxed);
                match send.write_all(&[channel]).await {
                    Ok(()) => {}
                    Err(WriteError::ConnectionLost(e)) if gone(&e) => {
                        tried_again = true;
                        continue;
                    }
                    Err(WriteError::ConnectionLost(e)) => return Err(why_lost(&e)),
                    Err(_) => return Err((OpenError::Unreachable, "The link was lost.".to_string())),
                }
                let mut answer = [0u8; 1];
                return match recv.read_exact(&mut answer).await {
                    Ok(()) if answer[0] == ACCEPTED => Ok((link, carried, send, recv)),
                    Ok(()) => {
                        turn_back(&mut send, &mut recv, code::BROKEN);
                        Err((OpenError::Refused, "It answered what is no answer.".to_string()))
                    }
                    Err(ReadExactError::ReadError(ReadError::Reset(code))) if code == VarInt::from_u32(code::REFUSED) => {
                        Err((OpenError::Refused, "It does not take that channel from this device.".to_string()))
                    }
                    Err(ReadExactError::ReadError(ReadError::ConnectionLost(e))) if gone(&e) => {
                        tried_again = true;
                        continue;
                    }
                    Err(ReadExactError::ReadError(ReadError::ConnectionLost(e))) => Err(why_lost(&e)),
                    Err(_) => Err((OpenError::Refused, "It closed the stream as it was opened.".to_string())),
                };
            }
        };
        // What the attempt came to, or that the wait ran out, or that this node stopped. The attempt itself, and with
        // it its place on the link, is gone by the end of this.
        enum Outcome {
            Came(Result<Opened, (OpenError, String)>),
            WaitedOut,
            Stopped,
        }
        let outcome = tokio::select! {
            _ = self.stop.cancelled() => Outcome::Stopped,
            came = timeout(wait.clamp(OPEN_SHORTEST, OPEN_LONGEST), attempt) => came.map(Outcome::Came).unwrap_or(Outcome::WaitedOut),
        };
        let opened = match outcome {
            Outcome::Came(opened) => opened,
            Outcome::Stopped => Err((OpenError::NotUp, "The direct network is not up.".to_string())),
            // The link is up and has no place for one more stream: nothing is wrong with the link.
            Outcome::WaitedOut if reached.load(Ordering::Relaxed) == 1 => {
                Err((OpenError::TooMany, "As many streams are open to it as one link carries.".to_string()))
            }
            Outcome::WaitedOut => {
                // A link that was up already, carries nothing else and does not answer is let go, so that the next try
                // dials. One that carries other streams is left to them: QUIC ends it within half a minute if the
                // other device has really gone.
                if let Some(link) = lock(&used).take()
                    && *link.streams.borrow() == 0
                {
                    link.end_with(code::IDLE, Closed::LinkLost);
                }
                Err((OpenError::Unreachable, "It did not answer in time.".to_string()))
            }
        };
        // Disallowed since it was asked, whatever the attempt came to (its link may have been closed under it): the
        // stream is given up, and so is the link where this open's own dial made it.
        let opened = if self.shared.let_go_count(&peer) != let_go {
            if let Ok((link, carried, mut send, mut recv)) = opened {
                turn_back(&mut send, &mut recv, code::NOT_ALLOWED);
                if lock(&used).is_none() {
                    link.end_with(code::NOT_ALLOWED, Closed::NotAllowed);
                }
                drop(carried);
            }
            Err((OpenError::TurnedAway, "This device no longer allows it.".to_string()))
        } else {
            opened
        };
        match opened {
            Ok((link, carried, send, recv)) => {
                let share = self.share(&link.peer);
                let (st, queue) = self.listed(&link, channel, false, link.stop.child_token(), 0, share);
                self.shared.say(Event::Opened { request, stream: st.id });
                self.pump(&link, st, send, recv, queue).await;
                drop(carried);
            }
            Err((why, message)) => fail(why, &message),
        }
    }

    /// The link to `peer`: the newest that is up, or a dial by the hint and by what iroh already knows of it.
    ///
    /// A link this dial makes to a node disallowed since the open was asked (`let_go`) is closed as soon as it is listed:
    /// LetGo, which closes what is listed, may have come while the dial was under way.
    async fn link_to(self: &Arc<Self>, peer: EndpointId, hint: &Hint, let_go: u64) -> Result<(Arc<Link>, bool), (OpenError, String)> {
        if let Some(link) = self.live_link(&peer) {
            return Ok((link, false));
        }
        let one = lock(&self.dialling).entry(peer).or_default().clone();
        let dialled = async {
            let _turn = one.lock().await;
            if let Some(link) = self.live_link(&peer) {
                return Ok((link, false));
            }
            let conn = self.ep.connect(self.dial_addr(peer, hint), ALPN).await.map_err(|e| why_no_link(&e))?;
            let link = self.linked(LinkConn::Full(conn), peer, false, false);
            if self.shared.let_go_count(&peer) != let_go {
                link.end_with(code::NOT_ALLOWED, Closed::NotAllowed);
                return Err((OpenError::TurnedAway, "This device no longer allows it.".to_string()));
            }
            Ok((link, true))
        }
        .await;
        // Nobody else waiting on this dial: its turn-keeper is not kept.
        let mut dialling = lock(&self.dialling);
        if Arc::strong_count(&one) <= 2 {
            dialling.remove(&peer);
        }
        dialled
    }

    /// The newest link to `peer` that is up and may carry a stream of this node's own: never a stranger's.
    fn live_link(&self, peer: &EndpointId) -> Option<Arc<Link>> {
        lock(&self.links).get(peer)?.iter().rev().find(|l| l.live() && !l.stranger).cloned()
    }

    /// Where to dial `peer`, from what it last said: its link helper only where that is one of this node's own (this
    /// node talks to no server the app did not name, whoever asks), and its addresses unless this node shows its own
    /// to nobody, each only where it is another device's ([`dialable`]).
    fn dial_addr(&self, peer: EndpointId, hint: &Hint) -> EndpointAddr {
        let mut addrs = Vec::new();
        if let Some(url) = hint.helper.as_deref().and_then(|h| h.parse::<RelayUrl>().ok())
            && self.helpers.iter().any(|(own, _)| *own == url)
        {
            addrs.push(TransportAddr::Relay(url));
        }
        if !self.helpers_only {
            for addr in hint.addresses.iter().take(MAX_ADDRESSES).filter_map(|a| a.parse::<SocketAddr>().ok()) {
                if dialable(&addr, LOOPBACK_DIALLED) {
                    addrs.push(TransportAddr::Ip(SocketAddr::new(addr.ip().to_canonical(), addr.port())));
                }
            }
        }
        EndpointAddr::from_parts(peer, addrs)
    }

    /// A stream is up: it is given its number, its queue and its windows, and listed for the app to send on.
    fn listed(
        &self,
        link: &Arc<Link>,
        channel: u8,
        incoming: bool,
        stop: CancellationToken,
        cost: usize,
        share: Arc<Semaphore>,
    ) -> (Arc<Stream>, mpsc::UnboundedReceiver<Out>) {
        let id = self.shared.next_stream.fetch_add(1, Ordering::Relaxed) + 1;
        let credit = Arc::new(Credit { window: Semaphore::new(TAKE_WINDOW), share, held: Mutex::new(0), stream: cost });
        lock(&self.credits).insert(id, credit.clone());
        let (out, queue) = mpsc::unbounded_channel();
        let st = Arc::new(Stream {
            id,
            peer: link.peer,
            channel,
            incoming,
            out,
            queued: Mutex::default(),
            close_asked: Notify::new(),
            stop,
            why: Mutex::new(None),
            credit,
        });
        lock(&self.streams).insert(id, st.clone());
        (st, queue)
    }

    /// Carries a stream until it ends, and says why it did.
    async fn pump(&self, link: &Link, st: Arc<Stream>, mut send: SendStream, mut recv: RecvStream, mut queue: mpsc::UnboundedReceiver<Out>) {
        /// Which of the four things a stream waits on came first.
        enum End {
            /// It, its link or the node was stopped.
            Stopped,
            /// The app closed it, and what was queued had not been written [`CLOSE_FLUSH`] later.
            Overdue,
            Read(ReadEnd),
            Wrote(WriteEnd),
        }
        let end = {
            let overdue = async {
                st.close_asked.notified().await;
                tokio::time::sleep(CLOSE_FLUSH).await;
            };
            tokio::select! {
                // In this order: a stream that was told to stop says so, whatever else has happened to it by then.
                biased;
                _ = st.stop.cancelled() => End::Stopped,
                _ = overdue => End::Overdue,
                end = self.read_frames(&st, &mut recv) => End::Read(end),
                end = self.write_frames(&st, &mut send, &mut queue) => End::Wrote(end),
            }
        };
        let why = match end {
            End::Wrote(WriteEnd::Finished) => {
                // Closed here, and everything queued before is written. The end is sent, and the other end given a
                // while to see it (it resets its own half when it does): so a frame sent just before a close, or a
                // close just before a stop, is not lost to what comes after.
                let _ = send.finish();
                let seen = async {
                    let mut rest = [0u8; 4096];
                    while let Ok(Some(_)) = recv.read(&mut rest).await {}
                };
                tokio::select! {
                    _ = st.stop.cancelled() => {}
                    _ = timeout(CLOSE_SEEN, seen) => {}
                }
                let _ = recv.stop(VarInt::from_u32(code::CLOSED));
                Closed::ByUs
            }
            End::Overdue => {
                turn_back(&mut send, &mut recv, code::CLOSED);
                Closed::ByUs
            }
            End::Read(ReadEnd::Ended) | End::Wrote(WriteEnd::StoppedByThem) => {
                turn_back(&mut send, &mut recv, code::CLOSED);
                Closed::ByThem
            }
            End::Read(ReadEnd::Broken) => {
                turn_back(&mut send, &mut recv, code::BROKEN);
                Closed::Broken
            }
            // The link went: by this node's own doing where it ended it (stopping, no longer allowing the other),
            // which is then what is said.
            End::Read(ReadEnd::Lost) | End::Wrote(WriteEnd::Lost) => {
                (*lock(&link.ended)).map(|(_, why)| why).unwrap_or(if self.stop.is_cancelled() { Closed::Stopped } else { Closed::LinkLost })
            }
            End::Stopped => {
                let why = (*lock(&st.why)).or((*lock(&link.ended)).map(|(_, why)| why)).unwrap_or(if self.stop.is_cancelled() {
                    Closed::Stopped
                } else {
                    Closed::LinkLost
                });
                turn_back(
                    &mut send,
                    &mut recv,
                    match why {
                        Closed::NotAllowed => code::NOT_ALLOWED,
                        Closed::Overflow => code::OVERFLOW,
                        Closed::Stopped => code::STOPPED,
                        _ => code::CLOSED,
                    },
                );
                why
            }
        };
        // Told to stop for a reason while it was ending another way: the reason it was given stands.
        let why = (*lock(&st.why)).unwrap_or(why);
        lock(&self.streams).remove(&st.id);
        lock(&st.queued).closing = true;
        self.shared.say(Event::Closed { stream: st.id, why });
    }

    /// Reads frames off a stream and hands each to the app, whole and in order, until the stream ends.
    async fn read_frames(&self, st: &Stream, recv: &mut RecvStream) -> ReadEnd {
        let mut pace = Bucket::new(FRAMES_PER_SECOND, FRAMES_PER_SECOND);
        loop {
            // No more frames a second than the app is to be handed: until it is time for the next, nothing is read.
            if let Err(wait) = pace.take() {
                tokio::time::sleep(wait).await;
                continue;
            }
            let mut head = [0u8; 4];
            match recv.read_exact(&mut head).await {
                Ok(()) => {}
                // Ended between two frames: closed.
                Err(ReadExactError::FinishedEarly(0)) => return ReadEnd::Ended,
                Err(ReadExactError::FinishedEarly(_)) => return ReadEnd::Broken,
                Err(ReadExactError::ReadError(e)) => return ReadEnd::of(e),
            }
            let len = u32::from_be_bytes(head) as usize;
            if len > MAX_FRAME {
                return ReadEnd::Broken;
            }
            // Room for it in what the app has not yet taken, of this stream's, of its sender's share and of the
            // node's, before a byte of it is read: while there is none, nothing is read, and QUIC holds the other node
            // back. If the other end gives the stream up meanwhile, that is seen without reading.
            let held = {
                let room = self.hold(&st.credit, len + FRAME_COST);
                tokio::pin!(room);
                tokio::select! {
                    held = &mut room => held,
                    reset = recv.received_reset() => match reset {
                        Ok(Some(_)) => return ReadEnd::Ended,
                        // It ended the stream after this frame: the frame is still to be read.
                        Ok(None) => room.await,
                        Err(_) => return ReadEnd::Lost,
                    },
                }
            };
            let by = Instant::now() + frame_time(len);
            // The frame, read straight into the buffer it is handed over in, made room for as the bytes come: never
            // more than the next step of a length the other node only said, and never more than the length.
            let mut frame = Vec::new();
            while frame.len() < len {
                let at = frame.len();
                grow(&mut frame, (len - at).min(READ_STEP), len);
                match timeout_at(by, recv.read_exact(&mut frame[at..])).await {
                    Ok(Ok(())) => {}
                    Ok(Err(ReadExactError::ReadError(e))) => return ReadEnd::of(e),
                    // Ended inside a frame, or left it half-sent.
                    Ok(Err(ReadExactError::FinishedEarly(_))) | Err(_) => return ReadEnd::Broken,
                }
            }
            held.keep();
            self.shared.say(Event::Frame { stream: st.id, frame });
        }
    }

    /// Writes a stream's queued frames, in order, until it is closed here or cannot be written to.
    async fn write_frames(&self, st: &Stream, send: &mut SendStream, queue: &mut mpsc::UnboundedReceiver<Out>) -> WriteEnd {
        let mut written = 0u64;
        let mut said = 0u64;
        loop {
            let Some(next) = queue.recv().await else { return WriteEnd::Lost };
            match next {
                Out::Finish => {
                    if written != said {
                        self.shared.say(Event::Sent { stream: st.id, frames: written });
                    }
                    return WriteEnd::Finished;
                }
                Out::Frame(bytes) => {
                    let writing = send.write_all(&bytes);
                    tokio::pin!(writing);
                    // Frames written and not yet said to be are said before this one is waited on for long: the other
                    // end may not be reading, and what did go must not seem stuck behind what has not.
                    let wrote = if written != said {
                        tokio::select! {
                            biased;
                            wrote = &mut writing => wrote,
                            _ = tokio::time::sleep(SAY_SENT_WITHIN) => {
                                said = written;
                                self.shared.say(Event::Sent { stream: st.id, frames: written });
                                writing.await
                            }
                        }
                    } else {
                        writing.await
                    };
                    if let Err(e) = wrote {
                        return match e {
                            WriteError::Stopped(_) => WriteEnd::StoppedByThem,
                            _ => WriteEnd::Lost,
                        };
                    }
                    {
                        let mut queued = lock(&st.queued);
                        queued.bytes = queued.bytes.saturating_sub(bytes.len());
                        queued.frames = queued.frames.saturating_sub(1);
                    }
                    written += 1;
                    if queue.is_empty() || written - said >= SAY_SENT_EVERY {
                        said = written;
                        self.shared.say(Event::Sent { stream: st.id, frames: written });
                    }
                }
            }
        }
    }

    /// Sets `cost` aside for a frame about to be read: of the stream's window, then of its sender's share, then of the
    /// node's budget. Waits where there is not that much; given back by itself if the frame never reaches the app.
    async fn hold<'a>(&'a self, credit: &'a Arc<Credit>, cost: usize) -> Held<'a> {
        if let Ok(permit) = credit.window.acquire_many(cost as u32).await {
            permit.forget();
        }
        if let Ok(permit) = credit.share.acquire_many(cost as u32).await {
            permit.forget();
        }
        if let Ok(permit) = self.budget.acquire_many(cost as u32).await {
            permit.forget();
        }
        *lock(&credit.held) += cost;
        Held { run: self, credit, cost }
    }

    /// Lets go of `cost` that was set aside for a stream, or of as much of it as is still set aside.
    fn give_back(&self, credit: &Credit, cost: usize) {
        let given = {
            let mut held = lock(&credit.held);
            let given = cost.min(*held);
            *held -= given;
            given
        };
        if given > 0 {
            credit.window.add_permits(given);
            credit.share.add_permits(given);
            self.budget.add_permits(given);
        }
    }

    /// Who is allowed has changed: a stream the other node opened on a channel it may no longer have is closed, and
    /// so is the link of a node that may no longer link (unless this node has a stream of its own on it): a node let
    /// in by name that is no longer, or a stranger once nothing is open to all.
    fn admission_changed(&self) {
        let admission = admission(&self.shared.admission);
        for st in lock(&self.streams).values() {
            if st.incoming && !admission.permits(&st.peer, st.channel) {
                st.stop_for(Closed::NotAllowed);
            }
        }
        for (peer, links) in lock(&self.links).iter() {
            for link in links.iter().filter(|l| l.incoming && l.ours.load(Ordering::Relaxed) == 0) {
                let still = if link.stranger { admission.admits(peer) } else { admission.allowed(peer) };
                if !still {
                    link.end_with(code::NOT_ALLOWED, Closed::NotAllowed);
                }
            }
        }
    }

    /// `disallow`: every link with the node is closed, and every stream with it.
    fn let_go(&self, peer: &EndpointId) {
        for link in lock(&self.links).get(peer).into_iter().flatten() {
            link.end_with(code::NOT_ALLOWED, Closed::NotAllowed);
        }
    }

    /// Tells the app where this node is, whenever that changes and no more than once a second.
    async fn tell_whereabouts(self: Arc<Self>) {
        let mut addr = self.ep.watch_addr();
        let mut told: Option<(Option<String>, Vec<String>)> = None;
        let mut told_at: Option<Instant> = None;
        // Where it is is said as soon as anything is known of it; where nothing is a moment after the node came up (no
        // address another device could reach it by, and no link helper it is on), that is said too, as it is: nowhere,
        // for now. The app then knows, and is not left waiting on something that may never come.
        let nowhere_at = Instant::now() + NOWHERE_AFTER;
        loop {
            let here = if self.helpers_only { Here::default() } else { Here::now() };
            let now = self.whereabouts(&addr.get(), &here);
            let news = match &told {
                Some(told) => *told != now,
                None => now.0.is_some() || !now.1.is_empty() || Instant::now() >= nowhere_at,
            };
            if news {
                let wait = told_at.map(|at| (at + WHEREABOUTS_EVERY).saturating_duration_since(Instant::now())).unwrap_or_default();
                if !wait.is_zero() {
                    tokio::select! {
                        _ = self.stop.cancelled() => return,
                        _ = tokio::time::sleep(wait) => continue,
                    }
                }
                self.shared.say(Event::Whereabouts { helper: now.0.clone(), addresses: now.1.clone() });
                told = Some(now);
                told_at = Some(Instant::now());
            }
            tokio::select! {
                _ = self.stop.cancelled() => return,
                changed = addr.updated() => if changed.is_err() { return },
                _ = tokio::time::sleep_until(nowhere_at), if told.is_none() => {}
            }
        }
    }

    /// The link helper this node is on, as the app wrote it, and the addresses worth telling ([`worth_telling`]).
    fn whereabouts(&self, addr: &EndpointAddr, here: &Here) -> (Option<String>, Vec<String>) {
        let helper = addr.relay_urls().find_map(|url| self.helpers.iter().find(|(own, _)| own == url).map(|(_, written)| written.clone()));
        if self.helpers_only {
            // It has no socket of its own, so iroh has no address of its own to give; and whatever iroh held, a node
            // that goes only through link helpers says its helper and nothing else.
            return (helper, Vec::new());
        }
        (helper, worth_telling(addr.ip_addrs().copied(), here).into_iter().map(|a| a.to_string()).collect())
    }
}

/// What was set aside for a frame being read. Kept once the frame is on its way to the app (which gives it back as
/// it takes the frame); given back here if the read ends before that.
struct Held<'a> {
    run: &'a Run,
    credit: &'a Credit,
    cost: usize,
}

impl Held<'_> {
    /// Leaves what was set aside counted: the frame is the app's to give back now.
    fn keep(self) {
        std::mem::forget(self);
    }
}

impl Drop for Held<'_> {
    fn drop(&mut self) {
        self.run.give_back(self.credit, self.cost);
    }
}

/// How the reading of a stream's frames ended.
enum ReadEnd {
    /// The other end closed the stream (its end came between two frames, or it reset it).
    Ended,
    /// What came was no frame.
    Broken,
    /// The link under it went.
    Lost,
}

impl ReadEnd {
    /// What a failed read means: a reset is the other end closing, anything else the link going.
    fn of(e: ReadError) -> ReadEnd {
        match e {
            ReadError::Reset(_) => ReadEnd::Ended,
            _ => ReadEnd::Lost,
        }
    }
}

/// How the writing of a stream's queued frames ended.
enum WriteEnd {
    /// Closed here, and everything before it written.
    Finished,
    /// The other end stopped reading: it closed the stream.
    StoppedByThem,
    /// The link under it went.
    Lost,
}

/// Gives up both halves of a stream at once, saying why.
fn turn_back(send: &mut SendStream, recv: &mut RecvStream, code: u32) {
    let _ = send.reset(VarInt::from_u32(code));
    let _ = recv.stop(VarInt::from_u32(code));
}

/// How a link's path stands: the one in use, or failing that the best there is.
fn standing(paths: &PathList<'_>) -> Option<(PathKind, Option<u32>)> {
    let path = paths.iter().find(|p| p.is_selected()).or_else(|| paths.iter().find(|p| p.is_ip())).or_else(|| paths.iter().find(|p| p.is_relay()))?;
    let kind = if path.is_ip() {
        PathKind::Direct
    } else if path.is_relay() {
        PathKind::Helper
    } else {
        return None;
    };
    let rtt = path.rtt();
    Some((kind, (!rtt.is_zero()).then(|| (rtt.as_micros().div_ceil(1000)).min(u32::MAX as u128 - 1) as u32)))
}

/// Whether a round trip is near enough to the one last said that saying it again would be noise.
fn close_enough(before: Option<u32>, now: Option<u32>) -> bool {
    match (before, now) {
        (Some(before), Some(now)) => before.abs_diff(now) <= (before / 4).max(10),
        (None, None) => true,
        _ => false,
    }
}

/// How useful an address of this node's is to another: public before private, and never one that means nothing off
/// this device (loopback, link-local, multicast, broadcast, unspecified or "this network").
fn rank(ip: &IpAddr) -> Option<u8> {
    match ip {
        IpAddr::V4(v4) => {
            if v4.is_unspecified() || v4.octets()[0] == 0 || v4.is_link_local() || v4.is_multicast() || v4.is_broadcast() || v4.is_loopback() {
                None
            } else if v4.is_private() || (v4.octets()[0] == 100 && v4.octets()[1] & 0xc0 == 64) {
                Some(2)
            } else {
                Some(0)
            }
        }
        IpAddr::V6(v6) => {
            if v6.is_unspecified() || v6.is_unicast_link_local() || v6.is_multicast() || v6.is_loopback() {
                None
            } else if v6.is_unique_local() {
                Some(3)
            } else {
                Some(1)
            }
        }
    }
}

/// Why a link ended, as `open` says it.
fn why_lost(e: &ConnectionError) -> (OpenError, String) {
    match e {
        ConnectionError::ApplicationClosed(closed) if closed.error_code == VarInt::from_u32(code::NOT_ALLOWED) => {
            (OpenError::TurnedAway, "It has not allowed this device.".into())
        }
        // Refused before a handshake (it came through a link helper, which said who was calling), or closed on in
        // the middle of one, where QUIC lets no reason of the app's own be given.
        ConnectionError::ConnectionClosed(closed)
            if closed.error_code == TransportErrorCode::CONNECTION_REFUSED || closed.error_code == TransportErrorCode::APPLICATION_ERROR =>
        {
            (OpenError::TurnedAway, "It has not allowed this device.".into())
        }
        ConnectionError::ApplicationClosed(closed) if closed.error_code == VarInt::from_u32(code::BUSY) => {
            (OpenError::Unreachable, "It has all the links it takes.".into())
        }
        ConnectionError::TimedOut => (OpenError::Unreachable, "It did not answer.".into()),
        _ => (OpenError::Unreachable, "The link was lost.".into()),
    }
}

/// Why no link could be made, as `open` says it.
fn why_no_link(e: &ConnectError) -> (OpenError, String) {
    match e {
        ConnectError::Connect { source: ConnectWithOptsError::NoAddress { .. }, .. } => {
            (OpenError::Unreachable, "Nothing is known of where it is.".into())
        }
        ConnectError::Connect { source: ConnectWithOptsError::SelfConnect { .. }, .. } => {
            (OpenError::BadRequest, "A node does not link with itself.".into())
        }
        ConnectError::Connecting { source: ConnectingError::ConnectionError { source, .. }, .. } => why_lost(source),
        ConnectError::Connection { source, .. } => why_lost(source),
        _ => (OpenError::Unreachable, "It could not be reached.".into()),
    }
}
