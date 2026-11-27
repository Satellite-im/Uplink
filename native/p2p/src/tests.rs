//! Nodes in one process, linked over this machine's own loopback and through a link helper run inside the test, by
//! the same calls the C interface makes. `cargo test` in native/p2p runs them; the three that only measure what an
//! idle node costs are run by name (`cargo test cost -- --ignored --nocapture`).

use std::{
    collections::{HashMap, VecDeque},
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    sync::Arc,
    time::Duration,
};

use iroh::{Endpoint, EndpointAddr, EndpointId, RelayMode, SecretKey, TransportAddr, endpoint::presets};
use tokio::{runtime::Handle, sync::mpsc, time::timeout};

use crate::{
    node::{
        ALPN, FRAME_COST, Here, LINK_IDLE, Limits, Local, NODE_BUDGET, Node, PEER_SHARE, SEND_QUEUE_BYTES, STREAM_COST, STREAMS_PER_LINK, SendError,
        TestSetup, dialable, first_port, frame_time, grow, helper, node_id, tunnel_interface, virtual_interface, worth_telling,
    },
    wire::{Channels, Closed, Config, Event, Hint, MAX_FRAME, OpenError, PathKind, hex},
};

/// How long anything is waited for before the test says it never came. Long: other builds share this machine.
const PATIENCE: Duration = Duration::from_secs(30);

/// A node and what it has said, as the app's side holds one: it takes each frame it is handed, and says when it
/// has handled a stream's end.
struct Dev {
    node: Node,
    said: mpsc::UnboundedReceiver<Event>,
    kept: VecDeque<Event>,
    secret: [u8; 32],
    id: [u8; 32],
    /// Whether it takes frames as it is handed them. A test turns it off to stand for an app that has stopped.
    takes: bool,
}

impl Dev {
    /// A node not yet started, whose key is 32 bytes of `n`: each test's devices take numbers of their own.
    fn new(n: u8) -> Dev {
        let (tx, said) = mpsc::unbounded_channel();
        let node = Node::new(&Handle::current(), move |events| {
            for event in events {
                let _ = tx.send(event);
            }
        });
        let secret = [n; 32];
        Dev { node, said, kept: VecDeque::new(), secret, id: node_id(&secret), takes: true }
    }

    /// What it is started with where the test names no link helper.
    fn config(&self) -> Config {
        Config { secret: self.secret, helpers: vec![], helpers_only: false }
    }

    /// The next event `want` is true of, whatever else came before it (which is kept, in order, for later).
    async fn next(&mut self, what: &str, mut want: impl FnMut(&Event) -> bool) -> Event {
        if let Some(at) = self.kept.iter().position(&mut want) {
            return self.kept.remove(at).expect("it is there");
        }
        let found = timeout(PATIENCE, async {
            loop {
                let event = self.said.recv().await.expect("the node's events ended");
                if want(&event) {
                    return event;
                }
                self.kept.push_back(event);
            }
        })
        .await;
        found.unwrap_or_else(|_| panic!("{} never came. Kept: {:?}", what, self.kept.iter().map(brief).collect::<Vec<_>>()))
    }

    /// Whether an event `want` is true of comes within `within`.
    async fn comes(&mut self, within: Duration, mut want: impl FnMut(&Event) -> bool) -> bool {
        if self.kept.iter().any(&mut want) {
            return true;
        }
        timeout(within, async {
            loop {
                let event = self.said.recv().await.expect("the node's events ended");
                let found = want(&event);
                self.kept.push_back(event);
                if found {
                    return;
                }
            }
        })
        .await
        .is_ok()
    }

    /// Everything it has said and not been asked for yet, and whatever it says in the next moment.
    async fn drain(&mut self) -> Vec<Event> {
        let mut all: Vec<Event> = self.kept.drain(..).collect();
        while let Ok(Some(event)) = timeout(Duration::from_millis(100), self.said.recv()).await {
            all.push(event);
        }
        all
    }

    /// Starts it, and waits for it to say it is up.
    async fn up(&mut self) {
        self.node.start(self.config());
        self.came_up().await;
    }

    /// Started on a network the test names, for the port it asks for there.
    async fn up_on(&mut self, network: &[u8]) {
        self.node.start_with(self.config(), TestSetup { network: Some(network.to_vec()), ..TestSetup::default() });
        self.came_up().await;
    }

    /// Waits for the answer to a start, which must be UP with the id its secret makes.
    async fn came_up(&mut self) {
        let id = self.id;
        match self.next("up", |e| matches!(e, Event::Up { .. } | Event::Down { .. })).await {
            Event::Up { node } => assert_eq!(node, id, "the node id is the one its secret makes"),
            other => panic!("it did not come up: {other:?}"),
        }
    }

    /// Stops it, and waits for it to say it is off.
    async fn off(&mut self) {
        self.node.stop();
        self.next("off", |e| matches!(e, Event::Off)).await;
    }

    /// Where it next says it is.
    async fn whereabouts(&mut self) -> (Option<String>, Vec<String>) {
        match self.next("whereabouts", |e| matches!(e, Event::Whereabouts { .. })).await {
            Event::Whereabouts { helper, addresses } => (helper, addresses),
            _ => unreachable!(),
        }
    }

    /// A hint that says only its loopback address: the port it is bound on, from where it says it is (the first time
    /// it says an IPv4 address of its own).
    async fn here(&mut self) -> Hint {
        loop {
            let (_, addresses) = self.whereabouts().await;
            if let Some(port) = addresses.iter().filter_map(|a| a.parse::<SocketAddr>().ok()).find(|a| a.is_ipv4()).map(|a| a.port()) {
                return Hint { helper: None, addresses: vec![format!("127.0.0.1:{port}")] };
            }
        }
    }

    /// Opens a stream to `to` on `channel`, given ten seconds: the stream's number, or why not.
    async fn open(&mut self, request: u32, to: [u8; 32], channel: u8, hint: &Hint) -> Result<u64, (OpenError, String)> {
        self.open_within(request, to, channel, hint, Duration::from_secs(10)).await
    }

    async fn open_within(&mut self, request: u32, to: [u8; 32], channel: u8, hint: &Hint, wait: Duration) -> Result<u64, (OpenError, String)> {
        self.node.open(request, to, channel, wait, hint.clone());
        match self
            .next("an answer to open", |e| matches!(e, Event::Opened { request: r, .. } | Event::OpenFailed { request: r, .. } if *r == request))
            .await
        {
            Event::Opened { stream, .. } => Ok(stream),
            Event::OpenFailed { why, message, .. } => {
                // Shown only where the test fails: why an open that should have gone another way went this one.
                eprintln!("open {request} failed: {why:?}, {message}");
                Err((why, message))
            }
            _ => unreachable!(),
        }
    }

    /// The next stream another node opened here: its number, who opened it, and on which channel.
    async fn incoming(&mut self) -> (u64, [u8; 32], u8) {
        match self.next("an incoming stream", |e| matches!(e, Event::Incoming { .. })).await {
            Event::Incoming { stream, node, channel } => (stream, node, channel),
            _ => unreachable!(),
        }
    }

    /// The next frame on `stream`, taken as the app takes it.
    async fn frame(&mut self, stream: u64) -> Vec<u8> {
        let event = self.next("a frame", |e| e.as_frame().is_some_and(|(s, _)| s == stream)).await;
        let frame = event.as_frame().expect("a frame").1.to_vec();
        if self.takes {
            self.node.taken(stream, 1, frame.len() as u32);
        }
        frame
    }

    /// Why `stream` closed; its end is then handled, as the app does.
    async fn closed(&mut self, stream: u64) -> Closed {
        match self.next("a stream's end", |e| matches!(e, Event::Closed { stream: s, .. } if *s == stream)).await {
            Event::Closed { why, .. } => {
                self.node.done(stream);
                why
            }
            _ => unreachable!(),
        }
    }

    /// Waits until `frames` frames of `stream` have been written.
    async fn sent(&mut self, stream: u64, frames: u64) {
        self.next("word of what was sent", |e| matches!(e, Event::Sent { stream: s, frames: n } if *s == stream && *n >= frames)).await;
    }

    /// Waits for the path to `of` to be said to be of `kind`; its round trip in milliseconds, where one was said.
    async fn path(&mut self, of: [u8; 32], kind: PathKind) -> Option<u32> {
        match self.next("a path", |e| matches!(e, Event::Path { node, kind: k, .. } if *node == of && *k == kind)).await {
            Event::Path { rtt_ms, .. } => rtt_ms,
            _ => unreachable!(),
        }
    }

    /// The budget is whole again: nothing read is still counted.
    async fn budget_is_whole(&self) {
        for _ in 0..200 {
            if self.node.budget_free() == Some(NODE_BUDGET) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
        panic!("the budget is not whole: {:?} of {NODE_BUDGET}", self.node.budget_free());
    }
}

/// What a test starts a node on a link helper inside the test with.
fn on_helper(map: &iroh::RelayMap) -> TestSetup {
    TestSetup { helper: Some(map.clone()), ..TestSetup::default() }
}

/// A stopped node's port can be bound again: at once, or within the moment the system takes to let a socket go.
async fn port_is_free(port: u16) -> std::io::Result<()> {
    let mut tries = 0;
    loop {
        match std::net::UdpSocket::bind((Ipv4Addr::UNSPECIFIED, port)) {
            Ok(_) => return Ok(()),
            Err(e) if tries >= 100 => return Err(e),
            Err(_) => {
                tries += 1;
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        }
    }
}

/// An event for a failure's message: a frame by its length, not its bytes.
fn brief(event: &Event) -> String {
    match event.as_frame() {
        Some((stream, frame)) => format!("Frame({stream}, {} bytes)", frame.len()),
        None => format!("{event:?}"),
    }
}

fn only(channels: &[u8]) -> Channels {
    Channels::of(channels)
}

/// Two nodes up, the second allowing the first channel 0, and where the second is.
async fn pair(a: u8, b: u8) -> (Dev, Dev, Hint) {
    let (mut one, mut two) = (Dev::new(a), Dev::new(b));
    one.up().await;
    two.up().await;
    two.node.allow(one.id, only(&[0]));
    let hint = two.here().await;
    (one, two, hint)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn frames_go_both_ways_whole_and_in_order() {
    let (mut a, mut b, hint) = pair(1, 2).await;
    let ours = a.open(1, b.id, 0, &hint).await.expect("a stream");
    let (theirs, from, channel) = b.incoming().await;
    assert_eq!((from, channel), (a.id, 0));

    let big: Vec<u8> = (0..MAX_FRAME).map(|i| (i * 31 % 251) as u8).collect();
    // One way: an empty frame, the longest there is, and a burst of small ones queued all at once.
    a.node.send(ours, b"").unwrap();
    a.node.send(ours, &big).unwrap();
    for i in 0..3000u32 {
        a.node.send(ours, format!("small {i}").as_bytes()).unwrap();
    }
    assert_eq!(b.frame(theirs).await, b"");
    assert!(b.frame(theirs).await == big, "the longest frame arrives as it was sent");
    for i in 0..3000u32 {
        assert_eq!(b.frame(theirs).await, format!("small {i}").as_bytes());
    }
    a.sent(ours, 3002).await;

    // And the other, on the same stream.
    b.node.send(theirs, b"").unwrap();
    b.node.send(theirs, &big).unwrap();
    for i in 0..3000u32 {
        b.node.send(theirs, &i.to_be_bytes()).unwrap();
    }
    assert_eq!(a.frame(ours).await, b"");
    assert!(a.frame(ours).await == big);
    for i in 0..3000u32 {
        assert_eq!(a.frame(ours).await, i.to_be_bytes());
    }
    b.sent(theirs, 3002).await;

    // A frame longer than the longest is not taken at all.
    assert_eq!(a.node.send(ours, &vec![0u8; MAX_FRAME + 1]), Err(SendError::TooLong));

    // Closed by the one that opened it: a last frame first, which the other end still gets; then both are done.
    a.node.send(ours, b"last").unwrap();
    a.node.close(ours);
    a.node.close(ours);
    assert_eq!(a.node.send(ours, b"after"), Err(SendError::NoStream));
    assert_eq!(b.frame(theirs).await, b"last");
    assert_eq!(b.closed(theirs).await, Closed::ByThem);
    assert_eq!(a.closed(ours).await, Closed::ByUs);
    assert_eq!(a.node.send(ours, b"after"), Err(SendError::NoStream));
    assert_eq!(b.node.send(theirs, b"after"), Err(SendError::NoStream));
    a.budget_is_whole().await;
    b.budget_is_whole().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_end_that_was_dialled_may_close_too_and_open_streams_of_its_own() {
    let (mut a, mut b, hint) = pair(3, 4).await;
    a.node.allow(b.id, only(&[0]));
    let ours = a.open(1, b.id, 0, &hint).await.expect("a stream");
    let (theirs, ..) = b.incoming().await;
    // The dialled end opens one back with no hint at all: the link that is up is the one used.
    let back = b.open(2, a.id, 0, &Hint::default()).await.expect("a stream back over the same link");
    let (back_here, from, _) = a.incoming().await;
    assert_eq!(from, b.id);
    b.node.send(back, b"over the link you made").unwrap();
    assert_eq!(a.frame(back_here).await, b"over the link you made");

    // The accepting end closes the first: the one that opened it sees the end after what was sent before it.
    b.node.send(theirs, b"then gone").unwrap();
    b.node.close(theirs);
    assert_eq!(a.frame(ours).await, b"then gone");
    assert_eq!(a.closed(ours).await, Closed::ByThem);
    assert_eq!(b.closed(theirs).await, Closed::ByUs);
    // The other stream is untouched by it.
    a.node.send(back_here, b"still here").unwrap();
    assert_eq!(b.frame(back).await, b"still here");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_node_that_was_never_allowed_is_turned_away() {
    let (mut a, mut b, hint) = pair(5, 6).await;
    let mut stranger = Dev::new(7);
    stranger.up().await;
    let (why, _) = stranger.open(1, b.id, 0, &hint).await.expect_err("turned away");
    assert_eq!(why, OpenError::TurnedAway);
    // Turned away again by the same answer, not by a link that half stood.
    let (why, _) = stranger.open(2, b.id, 0, &hint).await.expect_err("turned away again");
    assert_eq!(why, OpenError::TurnedAway);
    // The one that is allowed gets through meanwhile, and nothing of the stranger's ever reached the app.
    let ours = a.open(1, b.id, 0, &hint).await.expect("a stream");
    let (_, from, _) = b.incoming().await;
    assert_eq!(from, a.id);
    assert!(!b.kept.iter().any(|e| matches!(e, Event::Incoming { node, .. } | Event::Path { node, .. } if *node == stranger.id)));
    // Allowed now, the stranger links.
    b.node.allow(stranger.id, only(&[0]));
    stranger.open(3, b.id, 0, &hint).await.expect("a stream, once allowed");
    let (_, from, _) = b.incoming().await;
    assert_eq!(from, stranger.id);
    a.node.close(ours);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_node_allowed_one_channel_is_refused_another() {
    let (mut a, mut b, hint) = pair(8, 9).await;
    let (why, _) = a.open(1, b.id, 1, &hint).await.expect_err("refused");
    assert_eq!(why, OpenError::Refused);
    let ours = a.open(2, b.id, 0, &hint).await.expect("channel 0");
    let (theirs, _, channel) = b.incoming().await;
    assert_eq!(channel, 0);
    assert!(!b.kept.iter().any(|e| matches!(e, Event::Incoming { channel: 1, .. })));

    // Allowed both, then only channel 1: the stream on channel 0 is closed, a new one on channel 1 is taken.
    b.node.allow(a.id, only(&[0, 1]));
    let second = a.open(3, b.id, 1, &hint).await.expect("channel 1, once allowed");
    let (second_there, _, channel) = b.incoming().await;
    assert_eq!(channel, 1);
    b.node.allow(a.id, only(&[1]));
    assert_eq!(b.closed(theirs).await, Closed::NotAllowed);
    assert_eq!(a.closed(ours).await, Closed::ByThem);
    a.node.send(second, b"still allowed").unwrap();
    assert_eq!(b.frame(second_there).await, b"still allowed");
    let (why, _) = a.open(4, b.id, 0, &hint).await.expect_err("channel 0 is no longer allowed");
    assert_eq!(why, OpenError::Refused);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_channel_open_to_all_takes_anyone_and_only_on_that_channel() {
    let (mut host, mut anyone) = (Dev::new(10), Dev::new(11));
    host.up().await;
    anyone.up().await;
    let hint = host.here().await;
    let (why, _) = anyone.open(1, host.id, 1, &hint).await.expect_err("nothing is open yet");
    assert_eq!(why, OpenError::TurnedAway);
    host.node.open_to_all(only(&[1]));
    let (why, _) = anyone.open(2, host.id, 0, &hint).await.expect_err("channel 0 is not open to all");
    assert_eq!(why, OpenError::Refused);
    let ours = anyone.open(3, host.id, 1, &hint).await.expect("the open channel");
    let (theirs, from, channel) = host.incoming().await;
    assert_eq!((from, channel), (anyone.id, 1));
    anyone.node.send(ours, b"hello, whoever you are").unwrap();
    assert_eq!(host.frame(theirs).await, b"hello, whoever you are");
    // No longer open: the stream is closed, and nobody not allowed can come back.
    host.node.open_to_all(Channels::NONE);
    assert_eq!(host.closed(theirs).await, Closed::NotAllowed);
    assert!(matches!(anyone.closed(ours).await, Closed::ByThem | Closed::LinkLost));
    // (Turned away, or refused on the link that is closing under it: which comes first is a matter of moments.)
    let (why, _) = anyone.open(4, host.id, 1, &hint).await.expect_err("closed to all again");
    assert!(matches!(why, OpenError::TurnedAway | OpenError::Refused), "{why:?}");
    anyone.path(host.id, PathKind::None).await;
    let (why, _) = anyone.open(5, host.id, 1, &hint).await.expect_err("closed to all again");
    assert_eq!(why, OpenError::TurnedAway);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn disallow_closes_everything_with_that_node() {
    let (mut a, mut b, hint) = pair(12, 13).await;
    a.node.allow(b.id, only(&[0]));
    let ours = a.open(1, b.id, 0, &hint).await.expect("a stream");
    let (theirs, ..) = b.incoming().await;
    let back = b.open(1, a.id, 0, &Hint::default()).await.expect("a stream back");
    let (back_here, ..) = a.incoming().await;
    b.path(a.id, PathKind::Direct).await;

    b.node.disallow(a.id);
    assert_eq!(b.closed(theirs).await, Closed::NotAllowed);
    assert_eq!(b.closed(back).await, Closed::NotAllowed);
    b.path(a.id, PathKind::None).await;
    assert!(matches!(a.closed(ours).await, Closed::ByThem | Closed::LinkLost));
    assert!(matches!(a.closed(back_here).await, Closed::ByThem | Closed::LinkLost));
    a.path(b.id, PathKind::None).await;
    let (why, _) = a.open(2, b.id, 0, &hint).await.expect_err("no longer allowed");
    assert_eq!(why, OpenError::TurnedAway);
    a.budget_is_whole().await;
    b.budget_is_whole().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn stop_then_start_is_the_same_node_and_works_again_and_again() {
    let (mut a, mut b, mut hint) = pair(14, 15).await;
    for round in 0..4u32 {
        let ours = a.open(round, b.id, 0, &hint).await.unwrap_or_else(|e| panic!("round {round}: {e:?}"));
        let (theirs, from, _) = b.incoming().await;
        assert_eq!(from, a.id);
        a.node.send(ours, format!("round {round}").as_bytes()).unwrap();
        assert_eq!(b.frame(theirs).await, format!("round {round}").as_bytes());
        let port: u16 = hint.addresses[0].rsplit(':').next().unwrap().parse().unwrap();

        // Stopped: its streams say so, the other end's close, nothing can be sent or opened, and its port is free.
        b.off().await;
        assert_eq!(b.closed(theirs).await, Closed::Stopped);
        b.path(a.id, PathKind::None).await;
        assert!(matches!(a.closed(ours).await, Closed::ByThem | Closed::LinkLost));
        a.path(b.id, PathKind::None).await;
        assert_eq!(b.node.send(theirs, b"into nothing"), Err(SendError::NoStream));
        let (why, _) = b.open(100 + round, a.id, 0, &Hint::default()).await.expect_err("it is not up");
        assert_eq!(why, OpenError::NotUp);
        port_is_free(port).await.unwrap_or_else(|e| panic!("round {round}: the port {port} is still held after the stop: {e}"));
        let (why, _) = a.open_within(200 + round, b.id, 0, &hint, Duration::from_secs(2)).await.expect_err("nobody is there");
        assert_eq!(why, OpenError::Unreachable);

        // Started with the same secret: the same node id (`up` checks it), at the port it had, and who was allowed
        // is still allowed without being said again.
        b.up().await;
        hint = b.here().await;
        assert_eq!(port_of(&hint), port, "round {round}: it came back on another port");
    }
    // Started a second time with what it is already up with: nothing changes, and it says it is up.
    b.node.start(b.config());
    b.came_up().await;
    a.open(999, b.id, 0, &hint).await.expect("still the node it was");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_path_says_straight_and_none_once_an_idle_link_is_let_go() {
    let (mut a, mut b, hint) = pair(16, 17).await;
    let ours = a.open(1, b.id, 0, &hint).await.expect("a stream");
    let (theirs, ..) = b.incoming().await;
    let rtt = a.path(b.id, PathKind::Direct).await;
    assert!(rtt.is_some_and(|ms| ms < 1000), "a round trip on one machine: {rtt:?}");
    b.path(a.id, PathKind::Direct).await;
    a.node.close(ours);
    assert_eq!(b.closed(theirs).await, Closed::ByThem);
    assert_eq!(a.closed(ours).await, Closed::ByUs);
    // No stream is left on the link: it is let go, and both ends say there is no path.
    assert!(!a.comes(LINK_IDLE / 2, |e| matches!(e, Event::Path { kind: PathKind::None, .. })).await, "the link is kept a while");
    a.path(b.id, PathKind::None).await;
    b.path(a.id, PathKind::None).await;
    // And the next open dials again.
    a.open(2, b.id, 0, &hint).await.expect("a new link");
    a.path(b.id, PathKind::Direct).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn what_was_written_is_said_while_a_later_frame_waits() {
    let (mut a, mut b, hint) = pair(33, 34).await;
    let ours = a.open(1, b.id, 0, &hint).await.expect("a stream");
    let (theirs, ..) = b.incoming().await;
    // Three of the longest queued at once, to an app that is not taking: the first is read and handed over, the
    // second is not read for want of room, and the sender is held in the middle of it.
    b.takes = false;
    let big = vec![3u8; MAX_FRAME];
    for _ in 0..3 {
        a.node.send(ours, &big).unwrap();
    }
    assert!(b.frame(theirs).await == big);
    // The first is said to be written all the same, and no more than what was.
    a.sent(ours, 1).await;
    assert!(
        !a.comes(Duration::from_millis(500), |e| matches!(e, Event::Sent { frames, .. } if *frames >= 3)).await,
        "frames that were not read were said to be written"
    );
    assert!(!b.comes(Duration::from_millis(10), |e| e.as_frame().is_some()).await, "a frame was read that there was no room for");
    // Taken, the rest follow.
    b.takes = true;
    b.node.taken(theirs, 1, MAX_FRAME as u32);
    assert!(b.frame(theirs).await == big);
    assert!(b.frame(theirs).await == big);
    a.sent(ours, 3).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_queue_that_overflows_closes_the_stream_and_what_is_not_taken_is_not_read() {
    let (mut a, mut b, hint) = pair(18, 19).await;
    let ours = a.open(1, b.id, 0, &hint).await.expect("a stream");
    let (theirs, ..) = b.incoming().await;
    // The app at the far end stops taking frames. One frame of the most is handed to it; the next waits unread, QUIC
    // holds the sender back, and the sender's queue fills until the stream is closed for it.
    b.takes = false;
    let big = vec![7u8; MAX_FRAME];
    a.node.send(ours, &big).unwrap();
    assert!(b.frame(theirs).await == big);
    let mut queued = 0;
    let overflowed = loop {
        match a.node.send(ours, &big) {
            Ok(()) => queued += 1,
            Err(e) => break e,
        }
        assert!(queued <= 64, "the queue took {queued} frames of the most and never filled");
        tokio::time::sleep(Duration::from_millis(20)).await;
    };
    assert_eq!(overflowed, SendError::Overflow);
    assert!(queued >= SEND_QUEUE_BYTES / (MAX_FRAME + 4), "it held what a queue holds first: {queued}");
    assert_eq!(a.closed(ours).await, Closed::Overflow);
    assert_eq!(a.node.send(ours, b"more"), Err(SendError::NoStream));
    // The far end was handed that one frame and no more, however many were sent at it.
    assert_eq!(b.closed(theirs).await, Closed::ByThem);
    assert!(!b.kept.iter().any(|e| e.as_frame().is_some()), "nothing more was read than the app had room for");
    a.budget_is_whole().await;
    b.budget_is_whole().await;

    // The link is none the worse: a new stream carries frames, and they are counted while they are not taken.
    b.takes = true;
    let ours = a.open(2, b.id, 0, &hint).await.expect("a new stream");
    let (theirs, ..) = b.incoming().await;
    b.takes = false;
    a.node.send(ours, b"counted").unwrap();
    assert_eq!(b.frame(theirs).await, b"counted");
    assert_eq!(b.node.budget_free(), Some(NODE_BUDGET - STREAM_COST - FRAME_COST - 7));
    b.node.taken(theirs, 1, 7);
    assert_eq!(b.node.budget_free(), Some(NODE_BUDGET - STREAM_COST));
    // Saying more was taken than was handed over gives nothing more back.
    b.node.taken(theirs, 1000, 1 << 30);
    assert_eq!(b.node.budget_free(), Some(NODE_BUDGET - STREAM_COST));
}

/// What a test waits on that is not a node's event: in time, or the test says what never came.
async fn soon<T>(what: &str, f: impl Future<Output = T>) -> T {
    timeout(PATIENCE, f).await.unwrap_or_else(|_| panic!("{what} never came"))
}

/// A peer that is not this library: an iroh endpoint that speaks the protocol by hand, to say what a node must not
/// believe.
async fn by_hand(n: u8) -> Endpoint {
    Endpoint::builder(presets::Minimal).secret_key(SecretKey::from_bytes(&[n; 32])).bind().await.expect("an endpoint")
}

/// A node's address as iroh dials it, from its id and the addresses of a hint.
fn at(node: [u8; 32], hint: &Hint) -> EndpointAddr {
    EndpointAddr::from_parts(EndpointId::from_bytes(&node).unwrap(), hint.addresses.iter().map(|a| TransportAddr::Ip(a.parse().unwrap())))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn what_is_no_frame_closes_the_stream_and_nothing_else() {
    let mut b = Dev::new(20);
    b.up().await;
    let hint = b.here().await;
    let peer = by_hand(21).await;
    let peer_id = *peer.id().as_bytes();
    b.node.allow(peer_id, only(&[0]));
    let conn = soon("a link", peer.connect(at(b.id, &hint), ALPN)).await.expect("a link");
    let open = async |channel: u8| {
        let (mut send, mut recv) = soon("a stream", conn.open_bi()).await.unwrap();
        send.write_all(&[channel]).await.unwrap();
        let mut answer = [0u8; 1];
        let answered = soon("an answer to the channel", recv.read_exact(&mut answer)).await.map(|_| answer[0]);
        (send, recv, answered)
    };

    // A length past the most: the stream is closed as broken, and no room was ever made for what it claimed.
    {
        let (mut send, _recv, answered) = open(0).await;
        assert_eq!(answered.unwrap(), 1);
        let (stream, from, _) = b.incoming().await;
        assert_eq!(from, peer_id);
        send.write_all(&(MAX_FRAME as u32 + 1).to_be_bytes()).await.unwrap();
        assert_eq!(b.closed(stream).await, Closed::Broken);
        send.write_all(&u32::MAX.to_be_bytes()).await.ok();
    }

    // A frame cut short by the stream's end.
    {
        let (mut send, _recv, _) = open(0).await;
        let (stream, ..) = b.incoming().await;
        send.write_all(&10u32.to_be_bytes()).await.unwrap();
        send.write_all(b"abc").await.unwrap();
        send.finish().unwrap();
        assert_eq!(b.closed(stream).await, Closed::Broken);
    }

    // A length cut short by the stream's end.
    {
        let (mut send, _recv, _) = open(0).await;
        let (stream, ..) = b.incoming().await;
        send.write_all(&[0, 0]).await.unwrap();
        send.finish().unwrap();
        assert_eq!(b.closed(stream).await, Closed::Broken);
    }

    // A frame of the most, its length said a byte at a time and itself in pieces: it arrives whole. Then a clean end.
    {
        let (mut send, mut recv, _) = open(0).await;
        let (stream, ..) = b.incoming().await;
        let big = vec![5u8; MAX_FRAME];
        for byte in (MAX_FRAME as u32).to_be_bytes() {
            send.write_all(&[byte]).await.unwrap();
        }
        for piece in big.chunks(100_000) {
            send.write_all(piece).await.unwrap();
        }
        assert!(b.frame(stream).await == big);
        send.write_all(&[0, 0, 0, 2, b'o', b'k']).await.unwrap();
        assert_eq!(b.frame(stream).await, b"ok");
        b.node.send(stream, b"and back").unwrap();
        let mut back = [0u8; 12];
        soon("the frame back", recv.read_exact(&mut back)).await.unwrap();
        assert_eq!(&back, b"\0\0\0\x08and back");
        send.finish().unwrap();
        assert_eq!(b.closed(stream).await, Closed::ByThem);
    }

    // A channel it was not allowed: reset, with the code that says so, and the app never hears of it.
    {
        let (_send, _recv, answered) = open(9).await;
        assert!(
            matches!(answered, Err(iroh::endpoint::ReadExactError::ReadError(iroh::endpoint::ReadError::Reset(code))) if code == iroh::endpoint::VarInt::from_u32(2)),
            "{answered:?}"
        );
        assert!(!b.kept.iter().any(|e| matches!(e, Event::Incoming { channel: 9, .. })));
    }

    // More streams at once than a link carries: the next is not let through until one of them has ended. (A peer
    // that holds on to streams holds only its own places.)
    {
        let mut held = Vec::new();
        for _ in 0..STREAMS_PER_LINK {
            let (send, recv, answered) = open(0).await;
            assert_eq!(answered.unwrap(), 1);
            let (stream, ..) = b.incoming().await;
            held.push((send, recv, stream));
        }
        assert!(timeout(Duration::from_millis(500), conn.open_bi()).await.is_err(), "one stream more than a link carries was let through");
        let (send, recv, stream) = held.pop().unwrap();
        drop((send, recv));
        assert_eq!(b.closed(stream).await, Closed::ByThem);
        let (_send, _recv, answered) = open(0).await;
        assert_eq!(answered.unwrap(), 1);
        let (stream, ..) = b.incoming().await;
        // The link goes with all of them on it: each says so.
        conn.close(0u32.into(), b"");
        for stream in held.iter().map(|(_, _, stream)| *stream).chain([stream]) {
            assert_eq!(b.closed(stream).await, Closed::LinkLost);
        }
    }

    // A stranger speaking the same protocol by hand is closed on with the code that says it is not allowed.
    let stranger = by_hand(22).await;
    let turned_away = match soon("the stranger's handshake", stranger.connect(at(b.id, &hint), ALPN)).await {
        Ok(conn) => soon("the stranger's link to be closed", conn.closed()).await,
        Err(e) => panic!("the handshake itself failed: {e:#}"),
    };
    assert!(
        matches!(&turned_away, iroh::endpoint::ConnectionError::ApplicationClosed(c) if c.error_code == iroh::endpoint::VarInt::from_u32(1)),
        "{turned_away:?}"
    );
    // And a protocol of another name is not spoken at all.
    b.node.allow(*stranger.id().as_bytes(), only(&[0]));
    assert!(soon("another protocol's refusal", stranger.connect(at(b.id, &hint), b"ghost/2")).await.is_err());

    soon("the peer's endpoint to close", peer.close()).await;
    soon("the stranger's endpoint to close", stranger.close()).await;
    b.budget_is_whole().await;
}

/// A peer by hand that takes whoever links and answers each stream's channel, until the stream is ended.
fn takes_streams(peer: Endpoint) -> tokio::task::JoinHandle<Vec<iroh::endpoint::Connection>> {
    tokio::spawn(async move {
        let mut links = Vec::new();
        while let Some(incoming) = peer.accept().await {
            let Ok(conn) = incoming.await else { continue };
            links.push(conn.clone());
            tokio::spawn(async move {
                while let Ok((mut send, mut recv)) = conn.accept_bi().await {
                    let mut channel = [0u8; 1];
                    if recv.read_exact(&mut channel).await.is_ok() && send.write_all(&[1]).await.is_ok() {
                        let _ = recv.read_to_end(1 << 20).await;
                        let _ = send.reset(3u32.into());
                    }
                }
            });
            if links.len() == 1 {
                return links;
            }
        }
        links
    })
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_link_that_no_longer_answers_is_let_go_so_the_next_open_dials() {
    let mut a = Dev::new(31);
    a.up().await;
    let key = SecretKey::from_bytes(&[32; 32]);
    let listening = async || {
        let peer = Endpoint::builder(presets::Minimal).secret_key(key.clone()).alpns(vec![ALPN.to_vec()]).bind().await.expect("an endpoint");
        let port = peer.bound_sockets().iter().find(|a| a.is_ipv4()).expect("an IPv4 socket").port();
        (peer, Hint { helper: None, addresses: vec![format!("127.0.0.1:{port}")] })
    };
    let (peer, hint) = listening().await;
    let peer_id = *peer.id().as_bytes();
    let took = takes_streams(peer.clone());
    let ours = a.open(1, peer_id, 0, &hint).await.expect("a stream");
    a.node.close(ours);
    assert_eq!(a.closed(ours).await, Closed::ByUs);
    a.path(peer_id, PathKind::Direct).await;

    // The other device is gone without a word: no close, nothing. (Forgotten, not dropped: a handle that is dropped
    // says goodbye.)
    for link in soon("the peer's link", took).await.unwrap() {
        std::mem::forget(link);
    }
    drop(peer);
    tokio::time::sleep(Duration::from_millis(200)).await;
    // The link still looks up, so the next open tries it; nothing answers; and since it carries nothing else it is let
    // go at once, well before it would have been for being idle or QUIC would have given it up.
    let (why, _) = a.open_within(2, peer_id, 0, &hint, Duration::from_millis(800)).await.expect_err("nobody answers");
    assert_eq!(why, OpenError::Unreachable);
    assert!(
        a.comes(Duration::from_millis(1500), |e| matches!(e, Event::Path { node, kind: PathKind::None, .. } if *node == peer_id)).await,
        "the link that did not answer was kept"
    );
    // The device comes back somewhere else: the open dials there and is answered.
    let (peer, hint) = listening().await;
    let _took = takes_streams(peer.clone());
    a.open(3, peer_id, 0, &hint).await.expect("a stream to where it is now");
    soon("the peer's endpoint to close", peer.close()).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_node_that_links_again_replaces_its_earlier_link_and_an_open_under_way_goes_to_the_new_one() {
    let mut b = Dev::new(35);
    b.up().await;
    let hint = b.here().await;
    let peer = by_hand(36).await;
    let peer_id = *peer.id().as_bytes();
    b.node.allow(peer_id, only(&[0]));
    let first = soon("a link", peer.connect(at(b.id, &hint), ALPN)).await.expect("a link");
    b.path(peer_id, PathKind::Direct).await;
    // This node opens a stream to the peer over the link the peer made, and the peer, which has the stream, never
    // answers it.
    b.node.open(7, peer_id, 0, Duration::from_secs(20), Hint::default());
    let (_unanswered, mut asked) = soon("the stream", first.accept_bi()).await.expect("the stream");
    let mut channel = [9u8; 1];
    soon("its channel", asked.read_exact(&mut channel)).await.expect("its channel");
    assert_eq!(channel, [0]);
    // The peer links again (as a device does that has given a link up for lost). Its earlier link is let go here,
    // with the code that says why; and the open, which was waiting on that link, is not failed by this node's own
    // closing of it: it goes to the new link, where it is answered.
    let second = soon("a second link", peer.connect(at(b.id, &hint), ALPN)).await.expect("a second link");
    let (mut answer, mut asked) = soon("the stream, on the new link", second.accept_bi()).await.expect("the stream, on the new link");
    soon("its channel", asked.read_exact(&mut channel)).await.expect("its channel");
    answer.write_all(&[1]).await.unwrap();
    match b.next("an answer to open", |e| matches!(e, Event::Opened { request: 7, .. } | Event::OpenFailed { request: 7, .. })).await {
        Event::Opened { .. } => {}
        other => panic!("the open was failed by the link being replaced under it: {other:?}"),
    }
    let ended = soon("the earlier link to be closed", first.closed()).await;
    assert!(
        matches!(&ended, iroh::endpoint::ConnectionError::ApplicationClosed(c) if c.error_code == iroh::endpoint::VarInt::from_u32(6)),
        "{ended:?}"
    );
    assert!(second.close_reason().is_none());
    soon("the peer's endpoint to close", peer.close()).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_node_dials_only_by_what_it_may_and_says_why_it_cannot() {
    let (mut a, b, _hint) = pair(23, 24).await;
    // Nothing known of where it is: said at once, not after the wait.
    let before = std::time::Instant::now();
    let (why, _) = a.open(1, b.id, 0, &Hint::default()).await.expect_err("nothing to dial by");
    assert_eq!(why, OpenError::Unreachable);
    // A link helper this node was not given is not a server it will talk to, whoever names it: the hint comes to
    // nothing, at once.
    let (why, _) = a
        .open(2, b.id, 0, &Hint { helper: Some("https://helper.someone-else.example".into()), addresses: vec![] })
        .await
        .expect_err("not its helper");
    assert_eq!(why, OpenError::Unreachable);
    // Nor are addresses that are no addresses.
    let nonsense = Hint {
        helper: None,
        addresses: vec!["not an address".into(), "0.0.0.0:5".into(), "127.0.0.1:0".into(), "224.0.0.1:9".into(), "255.255.255.255:9".into()],
    };
    let (why, _) = a.open(3, b.id, 0, &nonsense).await.expect_err("nothing to dial by");
    assert_eq!(why, OpenError::Unreachable);
    assert!(before.elapsed() < Duration::from_secs(5), "three opens with nothing to dial by took {:?}", before.elapsed());
    // Itself.
    let (why, _) = a.open(4, a.id, 0, &Hint::default()).await.expect_err("itself");
    assert_eq!(why, OpenError::BadRequest);
    // An address where nobody is: the wait it was given, and no longer.
    let before = std::time::Instant::now();
    let nobody = Hint { helper: None, addresses: vec!["127.0.0.1:9".into()] };
    let (why, _) = a.open_within(5, b.id, 0, &nobody, Duration::from_millis(700)).await.expect_err("nobody there");
    assert_eq!(why, OpenError::Unreachable);
    assert!(before.elapsed() < Duration::from_secs(4), "an open given 700 ms took {:?}", before.elapsed());
    // A node that was started wrongly says so, and can be started rightly after.
    let mut c = Dev::new(25);
    c.node.start(Config { secret: c.secret, helpers: vec!["http://plain.example".into()], helpers_only: false });
    assert!(matches!(c.next("down", |e| matches!(e, Event::Down { .. })).await, Event::Down { problem } if problem.contains("https://")));
    c.node.start(Config { secret: c.secret, helpers: vec![], helpers_only: true });
    assert!(matches!(c.next("down", |e| matches!(e, Event::Down { .. })).await, Event::Down { .. }));
    c.up().await;
    assert_eq!(hex(&c.id).len(), 64);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn two_nodes_given_only_a_link_helper_find_each_other() {
    let (map, url, _helper) = iroh::test_utils::run_relay_server().await.expect("a link helper");
    let written = url.to_string().trim_end_matches('/').to_string();
    let (mut a, mut b) = (Dev::new(26), Dev::new(27));
    let config = |d: &Dev| Config { secret: d.secret, helpers: vec![written.clone()], helpers_only: false };
    a.node.start_with(config(&a), on_helper(&map));
    a.came_up().await;
    b.node.start_with(config(&b), on_helper(&map));
    b.came_up().await;
    b.node.allow(a.id, only(&[0]));
    // Where it is: on the helper, said as the app wrote it.
    let there = loop {
        let (helper, _) = b.whereabouts().await;
        if helper.is_some() {
            break helper;
        }
    };
    assert_eq!(there.as_deref(), Some(written.as_str()));

    // Dialled by the helper alone, not one address: the link is made through it.
    let hint = Hint { helper: there.clone(), addresses: vec![] };
    let ours = a.open(1, b.id, 0, &hint).await.expect("a stream through the helper");
    let (theirs, from, _) = b.incoming().await;
    assert_eq!(from, a.id);
    a.node.send(ours, b"found you").unwrap();
    assert_eq!(b.frame(theirs).await, b"found you");
    // Both on one machine, so the two then find the straight path by themselves.
    a.path(b.id, PathKind::Direct).await;
    b.path(a.id, PathKind::Direct).await;

    // A node that is not allowed gets nothing by the helper: refused before any handshake, it learns no address.
    let mut stranger = Dev::new(28);
    stranger.node.start_with(config(&stranger), on_helper(&map));
    stranger.came_up().await;
    let (why, _) = stranger.open(1, b.id, 0, &hint).await.expect_err("refused through the helper, before any handshake");
    assert_eq!(why, OpenError::TurnedAway);
    let learnt = stranger.node.knows_of(b.id).await;
    assert!(learnt.iter().all(|addr| addr.is_relay()), "a node that was turned away learnt an address: {learnt:?}");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn only_through_link_helpers_keeps_the_path_through_the_helper() {
    let (map, url, _helper) = iroh::test_utils::run_relay_server().await.expect("a link helper");
    let written = url.to_string().trim_end_matches('/').to_string();
    let (mut hidden, mut other) = (Dev::new(29), Dev::new(30));
    hidden.node.start_with(Config { secret: hidden.secret, helpers: vec![written.clone()], helpers_only: true }, on_helper(&map));
    hidden.came_up().await;
    other.node.start_with(Config { secret: other.secret, helpers: vec![written.clone()], helpers_only: false }, on_helper(&map));
    other.came_up().await;
    hidden.node.allow(other.id, only(&[0]));
    other.node.allow(hidden.id, only(&[0]));
    // It says the helper and never an address of its own.
    let (helper, addresses) = loop {
        let said = hidden.whereabouts().await;
        if said.0.is_some() {
            break said;
        }
        assert!(said.1.is_empty());
    };
    assert_eq!(helper.as_deref(), Some(written.as_str()));
    assert!(addresses.is_empty(), "it told its own addresses: {addresses:?}");
    let other_is_at = loop {
        let said = other.whereabouts().await;
        if said.0.is_some() && !said.1.is_empty() {
            break said;
        }
    };

    // Dialled by the other, through the helper: the path is the helper's and stays the helper's.
    let ours = other.open(1, hidden.id, 0, &Hint { helper: helper.clone(), addresses: vec![] }).await.expect("a stream through the helper");
    let (theirs, ..) = hidden.incoming().await;
    other.path(hidden.id, PathKind::Helper).await;
    hidden.path(other.id, PathKind::Helper).await;
    for i in 0..20u8 {
        other.node.send(ours, &[i; 1000]).unwrap();
        assert_eq!(hidden.frame(theirs).await, [i; 1000]);
        hidden.node.send(theirs, &[i]).unwrap();
        assert_eq!(other.frame(ours).await, [i]);
    }
    // And a stream the other way, by the other's addresses as well as its helper: its addresses are not used.
    let back =
        hidden.open(2, other.id, 0, &Hint { helper: other_is_at.0.clone(), addresses: other_is_at.1.clone() }).await.expect("a stream the other way");
    other.incoming().await;
    hidden.node.send(back, b"still through the helper").unwrap();
    tokio::time::sleep(Duration::from_secs(3)).await;
    assert!(!other.comes(Duration::from_millis(100), |e| matches!(e, Event::Path { kind: PathKind::Direct, .. })).await, "a straight path was made");
    assert!(!hidden.comes(Duration::from_millis(100), |e| matches!(e, Event::Path { kind: PathKind::Direct, .. })).await, "a straight path was made");
    // What the other has learnt of where the hidden one is: the helper, and nothing else.
    let known = other.node.knows_of(hidden.id).await;
    assert!(!known.is_empty() && known.iter().all(|addr| addr.is_relay()), "the other learnt an address of the hidden one's own: {known:?}");
}

/// The port a hint's one address names.
fn port_of(hint: &Hint) -> u16 {
    hint.addresses[0].rsplit(':').next().unwrap().parse().unwrap()
}

/// Where a node was last said to be is where it is after a stop and a start, and after the app has closed and
/// opened: it asks for the port its key makes for the network it is on the first time, and for the port it had there
/// every time after. A port that something else has taken is not waited for: it starts on another, which is then its
/// port on that network.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_node_keeps_its_port_and_takes_another_where_it_is_taken() {
    let home = b"192.168.1.0/24".to_vec();
    // The port a key makes: the same every time, its own, and never one a service is given.
    assert_eq!(first_port(&[81; 32], &home), first_port(&[81; 32], &home));
    let made: std::collections::HashSet<u16> = (0..=255u8).map(|n| first_port(&[n; 32], &home)).collect();
    assert!(made.len() > 240, "256 keys made {} ports between them", made.len());
    assert!(made.iter().all(|port| *port >= 49152));

    // A key whose port nothing on this machine has just now (another run of these tests may have the first tried).
    let free = |port: u16| std::net::UdpSocket::bind((Ipv4Addr::UNSPECIFIED, port)).is_ok();
    let n = (81..=120u8).find(|n| free(first_port(&[*n; 32], &home))).expect("a key whose port is free");
    let mut a = Dev::new(n);
    a.up_on(&home).await;
    let port = port_of(&a.here().await);
    assert_eq!(port, first_port(&a.secret, &home), "its first port is not the one its key makes");
    // Both kinds of address on the one port (where this machine has IPv6 at all): asking for a port loses neither.
    let sockets = a.node.sockets();
    let has_ipv6 = std::net::UdpSocket::bind((std::net::Ipv6Addr::UNSPECIFIED, 0)).is_ok();
    assert!(sockets.iter().any(|at| at.is_ipv4() && at.port() == port), "{sockets:?}");
    assert!(!has_ipv6 || sockets.iter().any(|at| at.is_ipv6() && at.port() == port), "no IPv6 socket on its port: {sockets:?}");

    // Stopped and started at once, again and again: the port it had.
    for round in 0..5 {
        a.off().await;
        a.up_on(&home).await;
        assert_eq!(port_of(&a.here().await), port, "round {round}: it came back on another port");
    }

    // Taken by something else while it is stopped: it starts all the same, on another port, and keeps that one.
    a.off().await;
    let taken = soon("its port to be free", async {
        loop {
            match std::net::UdpSocket::bind((Ipv4Addr::UNSPECIFIED, port)) {
                Ok(socket) => return socket,
                Err(_) => tokio::time::sleep(Duration::from_millis(20)).await,
            }
        }
    })
    .await;
    a.up_on(&home).await;
    let other = port_of(&a.here().await);
    assert_ne!(other, port, "two sockets have one port");
    drop(taken);
    a.off().await;
    a.up_on(&home).await;
    assert_eq!(port_of(&a.here().await), other);
    a.off().await;
}

/// The port does not follow a device from one network to the next: on another network a node asks for another port,
/// the one its key makes for that network, and back on the first it asks for the one it had there. (Two networks are
/// told apart by the networks of the interface the route to the internet goes by; the test names them.)
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_node_asks_for_another_port_on_another_network() {
    let (home, cafe) = (b"192.168.1.0/24".to_vec(), b"10.20.0.0/22,2001:db8:5:6::/64".to_vec());
    assert_ne!(first_port(&[90; 32], &home), first_port(&[90; 32], &cafe), "one key made one port for two networks");
    let spread: std::collections::HashSet<u16> = (0..64u8).map(|n| first_port(&[90; 32], format!("10.{n}.0.0/16").as_bytes())).collect();
    assert!(spread.len() > 56, "64 networks made {} ports between them", spread.len());
    let free = |port: u16| std::net::UdpSocket::bind((Ipv4Addr::UNSPECIFIED, port)).is_ok();
    let n = (90..=130u8).find(|n| free(first_port(&[*n; 32], &home)) && free(first_port(&[*n; 32], &cafe))).expect("a key whose ports are free");
    let mut a = Dev::new(n);
    a.up_on(&home).await;
    let at_home = port_of(&a.here().await);
    assert_eq!(at_home, first_port(&a.secret, &home));
    a.off().await;
    a.up_on(&cafe).await;
    let at_cafe = port_of(&a.here().await);
    assert_eq!(at_cafe, first_port(&a.secret, &cafe), "on another network it asked for the port it had on the first");
    a.off().await;
    a.up_on(&home).await;
    assert_eq!(port_of(&a.here().await), at_home, "back home it did not ask for the port it had there");
    a.off().await;
}

/// A link helper is its https address and nothing else. The port and the path the app wrote are kept; where this node
/// is seen from is asked by QUIC on UDP 7842 at the same name, which is what the helpers this app is given answer on
/// (an iroh that chose another port would leave every node with no address of its own to say); no token goes with it.
#[test]
fn a_link_helper_is_made_of_its_address_alone() {
    let made = helper(&"https://link.example:7843".parse().unwrap());
    assert_eq!(made.url.as_str(), "https://link.example:7843/");
    assert_eq!(made.quic.as_ref().map(|quic| quic.port), Some(7842));
    assert_eq!(made.auth_token, None);
    // Under a path, with or without its last stroke: the same helper, and the path is kept.
    let under = helper(&"https://link.example/helpers/one".parse().unwrap());
    assert_eq!(under.url.as_str(), "https://link.example/helpers/one/");
    assert_eq!(under.url, "https://link.example/helpers/one/".parse().unwrap());
}

/// A link helper is asked at the address the app wrote, over TLS, and nothing else is asked at its name: iroh's
/// captive-portal check, which asks `http://<the helper's name>/generate_204` on port 80 whatever the helper's own
/// port, is off. Seen by listening on this machine's port 80, where a helper at 127.0.0.1 would be asked, while a
/// node with no socket of its own starts on one (with a socket iroh lets the check go as soon as UDP has answered;
/// here, as on a network that carries no UDP, nothing does).
///
/// Where this machine gives a test no port 80 (Linux without root, or a server already on it) there is nothing to
/// see, and the test passes saying so. Another iroh on this machine with a helper at 127.0.0.1, made without this,
/// would be heard here too: a failure is worth one more run alone.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_link_helper_is_asked_nothing_on_port_80() {
    let Ok(door) = tokio::net::TcpListener::bind((Ipv4Addr::UNSPECIFIED, 80)).await else {
        eprintln!("port 80 is not this test's to listen on here: not looked at");
        return;
    };
    let (heard, mut asked) = mpsc::unbounded_channel::<String>();
    let listening = tokio::spawn(async move {
        loop {
            let Ok((caller, from)) = door.accept().await else { return };
            // Only what this machine itself asks is of interest; anything else that finds the port is let go.
            if !from.ip().is_loopback() {
                continue;
            }
            let heard = heard.clone();
            tokio::spawn(async move {
                let mut said = vec![0u8; 1024];
                let read = timeout(Duration::from_secs(2), async {
                    loop {
                        if caller.readable().await.is_err() {
                            return 0;
                        }
                        match caller.try_read(&mut said) {
                            Ok(n) => return n,
                            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
                            Err(_) => return 0,
                        }
                    }
                })
                .await
                .unwrap_or(0);
                let _ = heard.send(String::from_utf8_lossy(&said[..read]).into_owned());
            });
        }
    });

    let (map, url, _helper) = iroh::test_utils::run_relay_server().await.expect("a link helper");
    assert_eq!(url.host_str(), Some("127.0.0.1"), "the helper is not where this test listens");
    let written = url.to_string().trim_end_matches('/').to_string();
    let mut hidden = Dev::new(32);
    hidden.node.start_with(Config { secret: hidden.secret, helpers: vec![written], helpers_only: true }, on_helper(&map));
    hidden.came_up().await;
    // It is on its helper: iroh has looked at the network, and the check would have begun a fifth of a second in.
    while hidden.whereabouts().await.0.is_none() {}
    let asked_it = timeout(Duration::from_secs(2), async {
        loop {
            match asked.recv().await {
                Some(said) if said.contains("generate_204") => return said,
                Some(_) => {}
                None => std::future::pending::<()>().await,
            }
        }
    })
    .await;
    assert!(asked_it.is_err(), "the helper's name was asked on port 80, in plain HTTP: {asked_it:?}");
    listening.abort();
    hidden.off().await;
}

/// What an idle node costs, measured: run by name, with `cargo test cost -- --ignored --nocapture`. A minute each.
mod cost {
    use super::*;

    /// The node's own count of its traffic so far.
    async fn counted(dev: &Dev) -> (u64, u64, u64) {
        dev.node.traffic().expect("it is up")
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    #[ignore = "a minute of measuring, not a test"]
    async fn an_idle_node_with_no_links() {
        let mut a = Dev::new(40);
        a.up().await;
        a.whereabouts().await;
        tokio::time::sleep(Duration::from_secs(3)).await;
        let before = counted(&a).await;
        tokio::time::sleep(Duration::from_secs(60)).await;
        let after = counted(&a).await;
        println!(
            "COST no helper, no links, 60 s: sent {} bytes, received {} bytes in {} datagrams",
            after.0 - before.0,
            after.1 - before.1,
            after.2 - before.2
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    #[ignore = "a minute of measuring, not a test"]
    async fn two_linked_idle_nodes() {
        let (mut a, mut b, hint) = pair(41, 42).await;
        let _ours = a.open(1, b.id, 0, &hint).await.expect("a stream");
        b.incoming().await;
        a.path(b.id, PathKind::Direct).await;
        tokio::time::sleep(Duration::from_secs(5)).await;
        let (before_a, before_b) = (counted(&a).await, counted(&b).await);
        tokio::time::sleep(Duration::from_secs(60)).await;
        let (after_a, after_b) = (counted(&a).await, counted(&b).await);
        println!(
            "COST one link, one stream open, nothing said, 60 s: the dialling node sent {} bytes and received {} bytes in {} datagrams; the dialled node sent {} bytes and received {} bytes in {} datagrams",
            after_a.0 - before_a.0,
            after_a.1 - before_a.1,
            after_a.2 - before_a.2,
            after_b.0 - before_b.0,
            after_b.1 - before_b.1,
            after_b.2 - before_b.2
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    #[ignore = "a minute of measuring, not a test"]
    async fn an_idle_node_on_a_link_helper() {
        let (map, url, helper) = iroh::test_utils::run_relay_server().await.expect("a link helper");
        let written = url.to_string().trim_end_matches('/').to_string();
        let mut a = Dev::new(43);
        a.node.start_with(Config { secret: a.secret, helpers: vec![written], helpers_only: false }, on_helper(&map));
        a.came_up().await;
        while a.whereabouts().await.0.is_none() {}
        tokio::time::sleep(Duration::from_secs(5)).await;
        let helper_saw = || (helper.metrics().server.got_ping.get(), helper.metrics().server.qad_connections.get());
        let (before, saw_before) = (counted(&a).await, helper_saw());
        tokio::time::sleep(Duration::from_secs(60)).await;
        let (after, saw_after) = (counted(&a).await, helper_saw());
        println!(
            "COST on a link helper, no links, 60 s: over UDP (finding its own address by the helper) sent {} bytes, received {} bytes in {} datagrams, in {} exchanges; and over the connection to the helper itself (TLS over TCP, not in those numbers) {} pings, each answered",
            after.0 - before.0,
            after.1 - before.1,
            after.2 - before.2,
            saw_after.1 - saw_before.1,
            saw_after.0 - saw_before.0
        );
        drop(helper);
    }
}

/// Not a test of anything promised, a measurement of what is not closed (README.md, "What a caller that is turned
/// away can still learn"): how often a caller that reaches this node straight, and is turned away once its handshake
/// has said who it is, has by then been shown another address of this node's. iroh's hole punching answers a caller
/// by itself: the caller names addresses of its own, and this node sends each a small probe, from whichever of its
/// addresses reaches it. Here both are on one machine, so the probe to the caller's network address comes from this
/// node's network address, which the caller (who dialled 127.0.0.1) then knows.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "a measurement, not a test"]
async fn how_often_a_caller_turned_away_learns_an_address() {
    let mut b = Dev::new(60);
    b.up().await;
    let hint = b.here().await;
    let mut learnt = 0;
    let tries = 300u32;
    for n in 0..tries {
        let mut secret = [9u8; 32];
        secret[..4].copy_from_slice(&n.to_be_bytes());
        let caller = Endpoint::builder(presets::Minimal).secret_key(SecretKey::from_bytes(&secret)).bind().await.unwrap();
        if let Ok(conn) = soon("a handshake", caller.connect(at(b.id, &hint), ALPN)).await {
            soon("the close", conn.closed()).await;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
        let known = caller
            .remote_info(EndpointId::from_bytes(&b.id).unwrap())
            .await
            .map(|i| i.into_addrs().map(|a| a.into_addr()).collect::<Vec<_>>())
            .unwrap_or_default();
        if known.len() > 1 {
            learnt += 1;
            if learnt == 1 {
                println!("COST for example: {known:?}");
            }
        }
        caller.close().await;
    }
    println!("COST {learnt} of {tries} callers that were turned away had been shown another address");
}

// What the review of the core found (2026-11-23), each held to here.

/// A node started with smaller limits than every node has, so that a test can fill them with a few callers.
async fn up_with(n: u8, limits: Limits, helper: Option<&iroh::RelayMap>, helpers: Vec<String>) -> Dev {
    let mut dev = Dev::new(n);
    let config = Config { secret: dev.secret, helpers, helpers_only: false };
    dev.node.start_with(config, TestSetup { helper: helper.cloned(), limits: Some(limits), network: None });
    dev.came_up().await;
    dev
}

/// The address another device on this machine reaches `dev` at that is not loopback: the one it says (this machine's
/// own address on its network), so that a caller there comes from another address than the tests' callers on
/// 127.0.0.1.
async fn said(dev: &mut Dev) -> Hint {
    loop {
        let (_, addresses) = dev.whereabouts().await;
        if let Some(a) = addresses.iter().find(|a| a.parse::<SocketAddr>().is_ok_and(|a| a.is_ipv4())) {
            return Hint { helper: None, addresses: vec![a.clone()] };
        }
    }
}

/// A UDP relay on 127.0.0.1 in front of `victim` that passes on the first datagram its caller sends and nothing after,
/// and passes back whatever the victim answers: the victim takes the caller's first packet, answers it, and waits for
/// the rest of a handshake that never comes. (The review's probe: any machine that can send UDP to the port can do it.)
async fn stalling(victim: SocketAddr) -> SocketAddr {
    let socket = Arc::new(tokio::net::UdpSocket::bind("127.0.0.1:0").await.expect("a socket"));
    let at = socket.local_addr().expect("its address");
    tokio::spawn(async move {
        let (mut caller, mut passed) = (None, false);
        let mut buffer = vec![0u8; 65536];
        loop {
            let Ok((n, from)) = socket.recv_from(&mut buffer).await else { return };
            if from == victim {
                if let Some(caller) = caller {
                    let _ = socket.send_to(&buffer[..n], caller).await;
                }
            } else {
                caller = Some(from);
                if !passed {
                    passed = true;
                    let _ = socket.send_to(&buffer[..n], victim).await;
                }
            }
        }
    });
    at
}

/// `n` callers with keys of their own, each through a relay of its own that stalls it after its first packet: so many
/// handshakes begun with `victim`, from 127.0.0.1, that never end.
async fn stall(victim: [u8; 32], port: u16, n: usize) -> Vec<Endpoint> {
    let mut callers = Vec::new();
    for i in 0..n {
        let relay = stalling(SocketAddr::from((Ipv4Addr::LOCALHOST, port))).await;
        let caller = Endpoint::builder(presets::Minimal)
            .secret_key(SecretKey::from_bytes(&[(150 + i) as u8; 32]))
            .relay_mode(RelayMode::Disabled)
            .clear_address_lookup()
            .bind()
            .await
            .expect("an endpoint");
        let addr = EndpointAddr::from_parts(EndpointId::from_bytes(&victim).unwrap(), [TransportAddr::Ip(relay)]);
        let dialling = caller.clone();
        tokio::spawn(async move {
            let _ = timeout(Duration::from_secs(30), dialling.connect(addr, ALPN)).await;
        });
        callers.push(caller);
    }
    callers
}

/// Waits until `dev` has `n` handshakes under way in its pool for anyone, and a moment more to see it stays so.
async fn handshaking(dev: &Dev, n: usize) {
    for _ in 0..400 {
        if dev.node.handshaking().map(|(any, _)| any) >= Some(n) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(dev.node.handshaking().map(|(any, _)| any), Some(n), "handshakes under way");
}

/// Limits for the tests of the door: a small pool, callers stalled for the old ten seconds, and nobody asked to prove
/// their address, unless a test says otherwise.
fn door(handshakes: usize, per_source: usize) -> Limits {
    Limits { handshakes, per_source, identity: Duration::from_secs(10), retry_from: usize::MAX, ..Limits::USUAL }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn handshakes_stalled_from_one_address_leave_room_for_everyone_else() {
    let mut b = up_with(64, door(16, Limits::USUAL.per_source), None, vec![]).await;
    let mut a = Dev::new(65);
    a.up().await;
    b.node.allow(a.id, only(&[0]));
    let there = said(&mut b).await;
    let port = there.addresses[0].parse::<SocketAddr>().unwrap().port();
    // Twenty callers from one machine begin handshakes and never finish them: they take the places one address may.
    let _stalled = stall(b.id, port, 20).await;
    handshaking(&b, Limits::USUAL.per_source).await;
    // A device allowed, from another address, links in the moment it is given.
    a.open_within(1, b.id, 0, &there, Duration::from_secs(5)).await.expect("shut out by strangers' handshakes from another address");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_caller_has_three_seconds_to_say_who_it_is() {
    let limits = Limits { identity: Limits::USUAL.identity, ..door(8, 8) };
    assert_eq!(limits.identity, Duration::from_secs(3));
    let mut b = up_with(66, limits, None, vec![]).await;
    let mut a = Dev::new(67);
    a.up().await;
    b.node.allow(a.id, only(&[0]));
    let there = said(&mut b).await;
    let port = there.addresses[0].parse::<SocketAddr>().unwrap().port();
    // Every place is taken by callers that never say who they are.
    let _stalled = stall(b.id, port, 8).await;
    handshaking(&b, 8).await;
    // Each is let go three seconds in, so a device allowed that tries meanwhile gets in a moment after (its own QUIC
    // tries again a second, two, four on); under the old ten seconds it would not, in this wait.
    let began = std::time::Instant::now();
    a.open_within(1, b.id, 0, &there, Duration::from_secs(8)).await.expect("held out by callers that never said who they are");
    assert!(began.elapsed() < Duration::from_secs(8));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn under_pressure_a_caller_shows_it_is_where_it_says_before_anything_is_set_aside() {
    let limits = Limits { retry_from: 4, ..door(8, 8) };
    let mut b = up_with(68, limits, None, vec![]).await;
    let mut a = Dev::new(69);
    a.up().await;
    b.node.allow(a.id, only(&[0]));
    let there = said(&mut b).await;
    let port = there.addresses[0].parse::<SocketAddr>().unwrap().port();
    // Twelve callers: the first four are taken as they come; from then on each is asked to show it is where it says
    // (QUIC's retry), which a caller that cannot be answered there never gets past, so no more places are taken.
    let _stalled = stall(b.id, port, 12).await;
    handshaking(&b, 4).await;
    // A device that can be answered where it is shows it, and gets in.
    a.open_within(1, b.id, 0, &there, Duration::from_secs(5)).await.expect("a caller that can be answered was not let through");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_caller_through_a_link_helper_that_was_let_in_has_places_strangers_cannot_take() {
    let (map, url, _helper) = iroh::test_utils::run_relay_server().await.expect("a link helper");
    let written = url.to_string().trim_end_matches('/').to_string();
    let mut b = up_with(70, door(8, 8), Some(&map), vec![written.clone()]).await;
    let a = up_with(71, Limits::USUAL, Some(&map), vec![written.clone()]).await;
    b.node.allow(a.id, only(&[0]));
    let mut a = a;
    let on = loop {
        let (helper, addresses) = b.whereabouts().await;
        if helper.is_some() && !addresses.is_empty() {
            break (helper, addresses);
        }
    };
    let port = on.1.iter().filter_map(|a| a.parse::<SocketAddr>().ok()).find(|a| a.is_ipv4()).expect("an IPv4 address").port();
    // Every place for callers straight to its address is taken.
    let _stalled = stall(b.id, port, 8).await;
    handshaking(&b, 8).await;
    // The device it let in comes through the helper, which said who it is: it takes a place of its own.
    a.open_within(1, b.id, 0, &Hint { helper: on.0.clone(), addresses: vec![] }, Duration::from_secs(8))
        .await
        .expect("a device let in by name, through a helper, was shut out by strangers straight to the address");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_caller_turned_away_again_and_again_is_not_answered_for_a_while() {
    let limits = Limits { refusals: 3, ..Limits::USUAL };
    let mut b = up_with(72, limits, None, vec![]).await;
    let hint = b.here().await;
    // A stranger dialling from one address, each time afresh (an endpoint that knows only the address it is given:
    // one that has been turned away may have been shown another address of this node's, which is another source).
    let dial = async || {
        let caller = by_hand(73).await;
        let tried = timeout(Duration::from_millis(2500), async {
            match caller.connect(at(b.id, &hint), ALPN).await {
                Ok(conn) => Some(conn.closed().await),
                Err(_) => None,
            }
        })
        .await;
        caller.close().await;
        tried
    };
    for n in 0..3 {
        let closed = dial().await.expect("an answer").expect("a handshake");
        assert!(
            matches!(&closed, iroh::endpoint::ConnectionError::ApplicationClosed(c) if c.error_code == iroh::endpoint::VarInt::from_u32(1)),
            "refusal {n}: {closed:?}"
        );
    }
    // The fourth in the while gets no answer at all: no handshake's arithmetic is done for it.
    assert!(!matches!(dial().await, Ok(Some(_))), "a caller turned away three times in a while was answered again");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn one_node_holds_no_more_than_its_share_of_what_is_read_and_not_taken() {
    let (mut a, mut b, hint) = pair(74, 75).await;
    let mut streams = Vec::new();
    for request in 0..4 {
        let ours = a.open(request, b.id, 0, &hint).await.expect("a stream");
        let (theirs, ..) = b.incoming().await;
        streams.push((ours, theirs));
    }
    // The app stops taking, and each stream is sent two frames of the most. Four streams' windows would take four
    // frames; the sender's share takes two, and then nothing more of it is read.
    b.takes = false;
    let big = vec![1u8; MAX_FRAME];
    for (ours, _) in &streams {
        for _ in 0..2 {
            a.node.send(*ours, &big).unwrap();
        }
    }
    for _ in 0..2 {
        b.next("a frame", |e| e.as_frame().is_some()).await;
    }
    tokio::time::sleep(Duration::from_millis(800)).await;
    let held = NODE_BUDGET - b.node.budget_free().unwrap();
    assert!(held <= PEER_SHARE, "one node holds {held} of what is read and not taken; its share is {PEER_SHARE}");
    assert!(b.node.share_free(a.id).unwrap() < MAX_FRAME, "its share is not what holds it back");
    // Another node is not held up by it.
    let mut c = Dev::new(76);
    c.up().await;
    b.node.allow(c.id, only(&[0]));
    b.takes = true;
    let from_c = c.open(9, b.id, 0, &hint).await.expect("a stream from another node");
    let (at_b, ..) = b.incoming().await;
    c.node.send(from_c, &big).unwrap();
    assert!(b.frame(at_b).await == big);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_stream_hands_the_app_no_more_frames_a_second_than_it_should() {
    let mut b = Dev::new(77);
    b.up().await;
    let hint = b.here().await;
    let peer = by_hand(78).await;
    b.node.allow(*peer.id().as_bytes(), only(&[0]));
    let conn = soon("a link", peer.connect(at(b.id, &hint), ALPN)).await.expect("a link");
    let (mut send, mut recv) = soon("a stream", conn.open_bi()).await.unwrap();
    send.write_all(&[0]).await.unwrap();
    let mut answer = [0u8; 1];
    soon("its answer", recv.read_exact(&mut answer)).await.unwrap();
    let (stream, ..) = b.incoming().await;
    // Three thousand empty frames, as fast as they can go: they cost the app's thread as much as any frame each.
    let many = 3000usize;
    send.write_all(&vec![0u8; 4 * many]).await.unwrap();
    let began = std::time::Instant::now();
    for _ in 0..many {
        assert!(b.frame(stream).await.is_empty());
    }
    let took = began.elapsed();
    // A thousand at once, then a thousand a second: two seconds at the least for the rest.
    assert!(took >= Duration::from_millis(1700), "{many} frames were handed over in {took:?}");
    soon("the peer's endpoint to close", peer.close()).await;
}

#[test]
fn a_frame_whose_length_was_said_has_its_bytes_come_at_32_kib_a_second_at_least() {
    // The most a frame may take: ten seconds, and a second for every 32 KiB. (Was fifteen, and every 8 KiB: a frame of
    // the most could hold its room for 143 seconds.)
    assert_eq!(frame_time(0), Duration::from_secs(10));
    assert_eq!(frame_time(MAX_FRAME), Duration::from_secs(10 + 32));
    assert!(frame_time(MAX_FRAME) <= Duration::from_secs(45));
}

#[test]
fn a_frame_grows_as_its_bytes_come_and_never_past_its_length() {
    // In steps of 64 KiB to 600 000 bytes: room doubling as it goes, and never more than the frame's length (which is
    // what the budget counts), where a plain resize would leave it at a megabyte.
    let mut frame = Vec::new();
    let len = 600_000;
    while frame.len() < len {
        let step = (len - frame.len()).min(64 * 1024);
        grow(&mut frame, step, len);
        assert!(frame.capacity() <= len, "{} of room for a frame of {len}", frame.capacity());
    }
    assert_eq!(frame.len(), len);
    assert_eq!(frame.capacity(), len);
    // A frame of the most the same.
    let mut frame = Vec::new();
    while frame.len() < MAX_FRAME {
        let step = (MAX_FRAME - frame.len()).min(64 * 1024);
        grow(&mut frame, step, MAX_FRAME);
    }
    assert_eq!(frame.capacity(), MAX_FRAME);
}

/// A host with a channel open to all, and a stranger let in only by it.
async fn hosting(n: u8, helper: Option<&iroh::RelayMap>, helpers: Vec<String>) -> Dev {
    let mut host = Dev::new(n);
    let config = Config { secret: host.secret, helpers, helpers_only: false };
    host.node.start_with(config, TestSetup { helper: helper.cloned(), ..TestSetup::default() });
    host.came_up().await;
    host.node.open_to_all(only(&[1]));
    host
}

/// A node let in only because a channel is open to all is linked on the connection its handshake left, which iroh is
/// never handed: so iroh sends it no list of this node's addresses, follows no path to it, and keeps nothing of it
/// (what this node's iroh knows of it stays empty, where of a node let in by name it knows where it is). What it can
/// still learn is what any device that completes a handshake can (README.md, "What a node that links can learn"): the
/// address this node sends from towards each address it names, through iroh's hole punching. And the window QUIC keeps
/// for its link is counted against the budget while it is up.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_node_let_in_only_by_a_channel_open_to_all_is_never_handed_to_iroh() {
    let (map, url, _helper) = iroh::test_utils::run_relay_server().await.expect("a link helper");
    let written = url.to_string().trim_end_matches('/').to_string();
    let mut host = hosting(79, Some(&map), vec![written.clone()]).await;
    let on = loop {
        let (helper, addresses) = host.whereabouts().await;
        if helper.is_some() && !addresses.is_empty() {
            break helper;
        }
    };
    let mut stranger = up_with(80, Limits::USUAL, Some(&map), vec![written.clone()]).await;
    let mut friend = up_with(78, Limits::USUAL, Some(&map), vec![written]).await;
    host.node.allow(friend.id, only(&[0]));
    let ours = stranger.open(1, host.id, 1, &Hint { helper: on.clone(), addresses: vec![] }).await.expect("a stream on the channel open to all");
    let (theirs, from, _) = host.incoming().await;
    assert_eq!(from, stranger.id);
    stranger.node.send(ours, b"hub, please").unwrap();
    assert_eq!(host.frame(theirs).await, b"hub, please");
    host.node.send(theirs, b"hello, whoever you are").unwrap();
    assert_eq!(stranger.frame(ours).await, b"hello, whoever you are");
    friend.open(1, host.id, 0, &Hint { helper: on, addresses: vec![] }).await.expect("a stream from a node let in by name");
    host.incoming().await;
    tokio::time::sleep(Duration::from_secs(2)).await;
    assert!(host.node.knows_of(stranger.id).await.is_empty(), "the stranger's link was handed to iroh");
    assert!(!host.node.knows_of(friend.id).await.is_empty(), "a node let in by name is unknown to iroh: the test shows nothing");
    assert!(!host.kept.iter().any(|e| matches!(e, Event::Path { node, .. } if *node == stranger.id)), "a path to a stranger was said");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_strangers_link_is_counted_against_the_budget_while_it_is_up() {
    let mut host = hosting(81, None, vec![]).await;
    let hint = host.here().await;
    let mut stranger = Dev::new(82);
    stranger.up().await;
    let ours = stranger.open(1, host.id, 1, &hint).await.expect("a stream on the channel open to all");
    let (theirs, ..) = host.incoming().await;
    stranger.node.send(ours, b"hub, please").unwrap();
    assert_eq!(host.frame(theirs).await, b"hub, please");
    // What QUIC may hold for it unread, and the stream, are counted while it is up.
    let held = NODE_BUDGET - host.node.budget_free().unwrap();
    assert!(held >= 128 * 1024 + STREAM_COST, "a stranger's link counted {held} against the budget");
    assert!(host.node.knows_of(stranger.id).await.is_empty(), "the stranger's link was handed to iroh");
    // Gone, what it counted is given back.
    stranger.node.close(ours);
    stranger.closed(ours).await;
    host.closed(theirs).await;
    host.node.open_to_all(Channels::NONE);
    host.budget_is_whole().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_lifecycle_that_ends_by_a_bug_leaves_nothing_running_and_says_it_is_down() {
    let (mut a, mut b, hint) = pair(83, 84).await;
    let _ours = a.open(1, b.id, 0, &hint).await.expect("a stream");
    b.incoming().await;
    let port = port_of(&hint);
    b.node.fall();
    match b.next("down", |e| matches!(e, Event::Down { .. })).await {
        Event::Down { problem } => assert!(problem.contains("stopped by itself")),
        _ => unreachable!(),
    }
    // What was running is ended as a stop ends it: its links, its tasks, its sockets.
    port_is_free(port).await.unwrap_or_else(|e| panic!("the run of a lifecycle that fell still holds its port {port}: {e}"));
    a.path(b.id, PathKind::None).await;
    let (why, _) = a.open_within(2, b.id, 0, &hint, Duration::from_secs(2)).await.expect_err("nothing takes callers");
    assert_eq!(why, OpenError::Unreachable);
    // And a start is answered that it is down, not with silence.
    b.node.start(b.config());
    match b.next("an answer to the start", |e| matches!(e, Event::Up { .. } | Event::Down { .. })).await {
        Event::Down { .. } => {}
        other => panic!("a node whose lifecycle fell answered a start with {other:?}"),
    }
    b.node.open(3, a.id, 0, Duration::from_secs(1), Hint::default());
    assert!(matches!(
        b.next("an answer to open", |e| matches!(e, Event::OpenFailed { request: 3, .. })).await,
        Event::OpenFailed { why: OpenError::NotUp, .. }
    ));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_hint_never_takes_a_node_to_a_link_helper_it_was_not_given() {
    // Two link helpers: one the node was given, and another, which a hint names. The other is never so much as
    // connected to. (The test this replaces had no helper at all, so no connection to any could be made.)
    let (map, url, own) = iroh::test_utils::run_relay_server().await.expect("a link helper");
    let (_, other_url, other) = iroh::test_utils::run_relay_server().await.expect("another link helper");
    let written = url.to_string().trim_end_matches('/').to_string();
    let mut b = up_with(85, Limits::USUAL, Some(&map), vec![written.clone()]).await;
    let mut a = up_with(86, Limits::USUAL, Some(&map), vec![written]).await;
    b.node.allow(a.id, only(&[0]));
    while b.whereabouts().await.0.is_none() {}
    while a.whereabouts().await.0.is_none() {}
    let before = other.metrics().server.accepts.get();
    let elsewhere = Hint { helper: Some(other_url.to_string().trim_end_matches('/').to_string()), addresses: vec![] };
    let (why, _) = a.open_within(1, b.id, 0, &elsewhere, Duration::from_secs(3)).await.expect_err("not by a helper of someone else's");
    assert_eq!(why, OpenError::Unreachable);
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(other.metrics().server.accepts.get(), before, "the node connected to a link helper it was not given");
    assert!(own.metrics().server.accepts.get() >= 2, "the test's own helper took no connections: it shows nothing");
}

/// This machine's addresses as a test makes them up.
fn local(interface: &str, ip: &str, prefix: u8, temporary: bool) -> (IpAddr, Local) {
    let ip: IpAddr = ip.parse().unwrap();
    let network = match ip {
        IpAddr::V4(v4) => IpAddr::V4(Ipv4Addr::from(u32::from(v4) & (u32::MAX << (32 - prefix)))),
        IpAddr::V6(v6) => IpAddr::V6(Ipv6Addr::from(u128::from(v6) & (u128::MAX << (128 - prefix)))),
    };
    (ip, Local { interface: interface.into(), tunnel: virtual_interface(interface), temporary, stale: false, network: (network, prefix) })
}

#[test]
fn a_node_tells_the_addresses_of_the_network_it_is_on_and_no_others() {
    let here = Here {
        addrs: HashMap::from([
            local("en0", "192.168.18.60", 24, false),
            local("en0", "fe80::1", 64, false),
            local("en0", "2001:db8:1:2::abcd", 64, false),
            local("en0", "2001:db8:1:2::77", 64, true),
            local("bridge100", "10.211.55.2", 24, false),
            local("bridge101", "10.37.129.2", 24, false),
            local("utun4", "fd00:aa::5", 64, false),
            local("en7", "172.16.4.9", 16, false),
            local("lo0", "127.0.0.1", 8, false),
        ]),
        default: Some("en0".into()),
    };
    let found = [
        "192.168.18.60:5000",
        "[fe80::1]:5000",
        "[2001:db8:1:2::abcd]:5000",
        "[2001:db8:1:2::77]:5000",
        "10.211.55.2:5000",
        "10.37.129.2:5000",
        "[fd00:aa::5]:5000",
        "172.16.4.9:5000",
        "127.0.0.1:5000",
        // Where the internet sees it, which a link helper said: no interface here has it.
        "203.0.113.7:41000",
    ]
    .map(|a| a.parse::<SocketAddr>().unwrap());
    let told: Vec<String> = worth_telling(found.into_iter(), &here).into_iter().map(|a| a.to_string()).collect();
    // Public first; the privacy address and not the lasting one beside it; the network it is on; never a virtual
    // machine's bridge, a VPN's tunnel, another interface, link-local or loopback.
    assert_eq!(told, ["203.0.113.7:41000", "[2001:db8:1:2::77]:5000", "192.168.18.60:5000"]);
    // With no route to the internet that can be told, every interface but the virtual ones'.
    let here = Here { default: Some("utun4".into()), ..here };
    let told: Vec<String> = worth_telling(found.into_iter(), &here).into_iter().map(|a| a.to_string()).collect();
    assert_eq!(told, ["203.0.113.7:41000", "[2001:db8:1:2::77]:5000", "172.16.4.9:5000", "192.168.18.60:5000"]);
    for name in [
        "utun3",
        "bridge100",
        "vmnet8",
        "vboxnet0",
        "docker0",
        "br-5f2a",
        "veth12",
        "wg0",
        "tun0",
        "tailscale0",
        "awdl0",
        "llw0",
        "vEthernet (WSL)",
        "VirtualBox Host-Only Network",
        "ZeroTier One [8056c2e21c]",
    ] {
        assert!(virtual_interface(name), "{name}");
    }
    for name in ["en0", "en1", "eth0", "wlan0", "wlp3s0", "enp0s31f6", "rmnet_data0", "ccmni1", "Ethernet", "Wi-Fi"] {
        assert!(!virtual_interface(name), "{name}");
    }
}

/// What a Windows machine run by Hyper-V (every one of GitHub's Windows runners, which Azure runs) says of its one network
/// card: a name that is a GUID, "Ethernet" for people to read, and "Microsoft Hyper-V Network Adapter". That card is the
/// machine's way out, not a host's switch to virtual machines ("vEthernet (…)", "Hyper-V Virtual Ethernet Adapter"),
/// and its address is told. Taken for a switch, the node had nothing at all to tell, and said nothing.
#[test]
fn a_virtual_machines_own_network_card_is_its_way_out() {
    let guid = "{8B6C21F5-3C67-4A0E-9C1B-2E5D7F0A1B2C}";
    assert!(!tunnel_interface(guid, Some("Ethernet"), Some("Microsoft Hyper-V Network Adapter"), false));
    assert!(!tunnel_interface(guid, Some("Ethernet 2"), Some("Mellanox ConnectX-4 Lx Virtual Ethernet Adapter"), false));
    assert!(tunnel_interface(guid, Some("vEthernet (WSL)"), Some("Hyper-V Virtual Ethernet Adapter"), false));
    assert!(tunnel_interface(guid, Some("vEthernet (Default Switch)"), Some("Hyper-V Virtual Ethernet Adapter #2"), false));
    assert!(tunnel_interface(guid, Some("Loopback Pseudo-Interface 1"), Some("Software Loopback Interface 1"), false));
    assert!(tunnel_interface("tunsnx", None, None, false));
    assert!(tunnel_interface("{0}", Some("Ethernet 3"), Some("Some adapter"), true), "one the system calls a tunnel");
    let card = |ip: &str, prefix: u8| {
        let (ip, mut local) = local(guid, ip, prefix, false);
        local.tunnel = tunnel_interface(guid, Some("Ethernet"), Some("Microsoft Hyper-V Network Adapter"), false);
        (ip, local)
    };
    let here = Here { addrs: HashMap::from([card("10.1.0.207", 16), card("fe80::4d:1", 64)]), default: Some(guid.into()) };
    let found = ["10.1.0.207:50432", "[fe80::4d:1]:50432"].map(|a| a.parse::<SocketAddr>().unwrap());
    let told: Vec<String> = worth_telling(found.into_iter(), &here).into_iter().map(|a| a.to_string()).collect();
    assert_eq!(told, ["10.1.0.207:50432"]);
}

/// A machine with an address another device could reach it by always tells one: where the interface its route goes
/// by looks like a tunnel and there is no other, that interface's; where no route is known at all, any interface's.
#[test]
fn a_machine_with_an_address_always_tells_one() {
    let found = ["10.8.0.6:41000", "[fe80::1]:41000"].map(|a| a.parse::<SocketAddr>().unwrap());
    let tunnel_only = HashMap::from([local("utun4", "10.8.0.6", 24, false), local("utun4", "fe80::1", 64, false)]);
    let told = |default: Option<&str>| -> Vec<String> {
        let here = Here { addrs: tunnel_only.clone(), default: default.map(str::to_string) };
        worth_telling(found.into_iter(), &here).into_iter().map(|a| a.to_string()).collect()
    };
    assert_eq!(told(Some("utun4")), ["10.8.0.6:41000"], "the route's own interface, a tunnel and the only one");
    assert_eq!(told(None), ["10.8.0.6:41000"], "no route known: any interface");
    // Where there is a network beside the tunnel, that is told, and the tunnel is not.
    let mut both = tunnel_only.clone();
    both.extend([local("en0", "192.168.1.20", 24, false)]);
    let here = Here { addrs: both, default: Some("utun4".into()) };
    let found = ["10.8.0.6:41000", "192.168.1.20:41000"].map(|a| a.parse::<SocketAddr>().unwrap());
    let told: Vec<String> = worth_telling(found.into_iter(), &here).into_iter().map(|a| a.to_string()).collect();
    assert_eq!(told, ["192.168.1.20:41000"]);
}

/// A node that can be found nowhere (no address of its own to tell, and no link helper it is on: here one that goes
/// only through link helpers, whose helper does not answer) says so a moment after it comes up, as an empty
/// WHEREABOUTS, rather than nothing at all.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_node_that_can_be_found_nowhere_says_so() {
    let mut lost = Dev::new(124);
    lost.node.start(Config { secret: lost.secret, helpers: vec!["https://127.0.0.1:9".into()], helpers_only: true });
    lost.came_up().await;
    let began = std::time::Instant::now();
    assert_eq!(lost.whereabouts().await, (None, vec![]));
    let after = began.elapsed();
    assert!(after >= Duration::from_secs(2) && after < Duration::from_secs(10), "said after {after:?}");
    lost.off().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn on_this_machine_a_node_tells_no_address_of_a_virtual_machine_or_a_tunnel() {
    let mut a = Dev::new(87);
    a.up().await;
    let (_, told) = a.whereabouts().await;
    let here = Here::now_for_tests();
    for address in &told {
        let ip = address.parse::<SocketAddr>().unwrap().ip();
        if let Some(local) = here.addrs.get(&ip) {
            assert!(!local.tunnel, "it told {address}, on {}", local.interface);
            assert!(!ip.is_loopback() && !matches!(ip, IpAddr::V6(v6) if v6.is_unicast_link_local()), "it told {address}");
        }
    }
}

#[test]
fn a_hint_is_dialled_only_where_it_names_another_device() {
    let yes = [
        "192.168.1.20:5000",
        "10.0.0.5:1",
        "100.64.3.2:9",
        "203.0.113.5:7",
        "[2001:db8::5]:7",
        "[fd12::5]:7",
        "[::ffff:203.0.113.5]:7",
        "[64:ff9b::cb00:7105]:7",
    ];
    let no = [
        "127.0.0.1:5000",
        "127.9.9.9:5000",
        "[::1]:5000",
        "[::ffff:127.0.0.1]:5000",
        "[64:ff9b::7f00:1]:5000",
        "[::127.0.0.1]:5000",
        "0.0.0.0:5000",
        "0.1.2.3:5000",
        "[::]:5000",
        "169.254.10.1:5000",
        "[::ffff:169.254.10.1]:5000",
        "[fe80::1]:5000",
        "224.0.0.251:5353",
        "[ff02::fb]:5353",
        "255.255.255.255:9",
        "192.168.1.20:0",
    ];
    for a in yes {
        assert!(dialable(&a.parse().unwrap(), false), "{a}");
    }
    for a in no {
        assert!(!dialable(&a.parse().unwrap(), false), "{a}");
    }
    // The tests' own nodes, all on one machine, dial loopback; nothing else does.
    assert!(dialable(&"127.0.0.1:5000".parse().unwrap(), true));
}

#[test]
fn the_node_key_is_written_over_when_its_config_goes() {
    let mut config = std::mem::ManuallyDrop::new(Config { secret: [0x5a; 32], helpers: vec![], helpers_only: false });
    // SAFETY: dropped once, in place; its bytes are read after only as the plain array they are.
    unsafe { std::ptr::drop_in_place(&mut *config) };
    assert_eq!(config.secret, [0u8; 32]);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_stream_opened_in_early_data_is_never_taken() {
    // A peer that has linked once holds a ticket to link again with early data (QUIC's 0-RTT, which anyone who saw it
    // could send again, and which iroh's TLS takes). A stream it opens in that early data is never taken: the link is
    // closed for it, and the app hears nothing. Linking again without early data, it is taken.
    let mut b = Dev::new(88);
    b.up().await;
    let hint = b.here().await;
    let peer = by_hand(89).await;
    b.node.allow(*peer.id().as_bytes(), only(&[0]));
    let first = soon("a link", peer.connect(at(b.id, &hint), ALPN)).await.expect("a link");
    tokio::time::sleep(Duration::from_millis(300)).await;
    first.close(0u32.into(), b"");
    tokio::time::sleep(Duration::from_millis(300)).await;
    let connecting = peer.connect_with_opts(at(b.id, &hint), ALPN, Default::default()).await.expect("a dial");
    let early = match connecting.into_0rtt() {
        Ok(early) => early,
        Err(_) => panic!("no ticket for early data: the test shows nothing"),
    };
    let (mut send, mut recv) = early.open_bi().await.expect("a stream in early data");
    send.write_all(&[0, 0, 0, 0, 3, b'e', b'a', b'r']).await.unwrap();
    let mut answer = [0u8; 1];
    let answered = soon("an answer to the early stream", recv.read_exact(&mut answer)).await;
    assert!(answered.is_err(), "a stream opened in early data was answered");
    // (Closed while its handshake was still under way, where QUIC carries no reason of the app's own.)
    let closed = soon("the link to close", early.closed()).await;
    assert!(
        matches!(&closed, iroh::endpoint::ConnectionError::ApplicationClosed(c) if c.error_code == iroh::endpoint::VarInt::from_u32(2))
            || matches!(&closed, iroh::endpoint::ConnectionError::ConnectionClosed(c) if c.error_code == iroh::endpoint::TransportErrorCode::APPLICATION_ERROR),
        "{closed:?}"
    );
    assert!(!b.comes(Duration::from_millis(500), |e| matches!(e, Event::Incoming { .. })).await, "a stream opened in early data was taken");
    // Without early data, the same peer is taken.
    let again = soon("a link", peer.connect(at(b.id, &hint), ALPN)).await.expect("a link");
    let (mut send, mut recv) = soon("a stream", again.open_bi()).await.unwrap();
    send.write_all(&[0]).await.unwrap();
    soon("its answer", recv.read_exact(&mut answer)).await.expect("taken without early data");
    b.incoming().await;
    soon("the peer's endpoint to close", peer.close()).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_link_takes_only_so_many_streams_opened_in_a_while() {
    let mut b = Dev::new(90);
    b.up().await;
    let hint = b.here().await;
    let peer = by_hand(91).await;
    b.node.allow(*peer.id().as_bytes(), only(&[0]));
    let conn = soon("a link", peer.connect(at(b.id, &hint), ALPN)).await.expect("a link");
    let (mut taken, mut turned) = (0, 0);
    for _ in 0..60 {
        let (mut send, mut recv) = soon("a stream", conn.open_bi()).await.unwrap();
        send.write_all(&[0]).await.unwrap();
        let mut answer = [0u8; 1];
        match soon("an answer", recv.read_exact(&mut answer)).await {
            Ok(()) => taken += 1,
            Err(_) => turned += 1,
        }
        let _ = send.reset(0u32.into());
        let _ = recv.stop(0u32.into());
    }
    // Thirty-two at once, then two a second: of sixty opened in a moment, the rest are turned back, and the app hears
    // only of those it took.
    assert!((32..=40).contains(&taken), "{taken} of 60 were taken");
    assert_eq!(taken + turned, 60);
    tokio::time::sleep(Duration::from_millis(300)).await;
    let heard = b.drain().await.iter().filter(|e| matches!(e, Event::Incoming { .. })).count();
    assert!(heard <= taken, "the app heard of {heard} streams; {taken} were taken");
    soon("the peer's endpoint to close", peer.close()).await;
}

/// Not a test: the Mac's end of the run on Android (integration_test/p2p_core_test.dart). A node on our link helper,
/// started as the app would start it (https://gogho.st:7843, its name asked of this machine's DNS, its certificate held
/// to the roots compiled in), that lets in the node the emulator's test starts (key 0xa6…) and answers each frame it is
/// sent, for five minutes: `cargo test --release android_partner -- --ignored --nocapture`, then hand the node id it
/// prints to the emulator's test as P2P_PARTNER.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "the Mac's end of the run on Android, by hand"]
async fn android_partner() {
    let emulator = node_id(&[0xa6; 32]);
    let mut me = Dev::new(0xa5);
    me.node.start(Config { secret: me.secret, helpers: vec!["https://gogho.st:7843".into()], helpers_only: false });
    me.came_up().await;
    me.node.allow(emulator, only(&[0]));
    println!("PARTNER {}", hex(&me.id));
    while me.whereabouts().await.0.is_none() {}
    println!("PARTNER on the link helper");
    let until = std::time::Instant::now() + Duration::from_secs(300);
    while std::time::Instant::now() < until {
        if !me.comes(Duration::from_secs(5), |e| matches!(e, Event::Incoming { .. })).await {
            continue;
        }
        let (stream, from, _) = me.incoming().await;
        println!("PARTNER a stream, from the emulator's node: {}", from == emulator);
        let frame = me.frame(stream).await;
        println!("PARTNER heard: {}", String::from_utf8_lossy(&frame));
        me.node.send(stream, b"hello from the Mac").unwrap();
        let kind = match me.next("a path", |e| matches!(e, Event::Path { node, .. } if *node == emulator)).await {
            Event::Path { kind, .. } => kind,
            _ => unreachable!(),
        };
        println!("PARTNER the path to it: {kind:?}");
    }
    me.off().await;
}

// What the review of Direct's switch found (2026-11-23), each held to here.

/// DISALLOW closes what is listed; an open whose dial was still under way when it came made its link only after, and
/// that link was carried and its stream handed over, frames and all, from a node no longer allowed. Now the open fails
/// and its link is closed; and an open asked after the node is allowed again is not held to the disallow before it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_open_under_way_when_its_node_is_disallowed_fails_and_hands_nothing_over() {
    let (mut a, mut b, hint) = pair(230, 231).await;
    a.node.allow(b.id, only(&[0]));
    for round in 0..3u32 {
        a.node.open(round, b.id, 0, Duration::from_secs(10), hint.clone());
        a.node.disallow(b.id);
        let answer = a
            .next("an answer to the open", |e| matches!(e, Event::Opened { request, .. } | Event::OpenFailed { request, .. } if *request == round))
            .await;
        match answer {
            Event::OpenFailed { why, .. } => assert_eq!(why, OpenError::TurnedAway, "round {round}"),
            other => panic!("round {round}: the open to a node disallowed while it was dialled came to {other:?}"),
        }
        // Whatever the other end took of it is closed, and nothing of it reaches this node's app.
        if b.comes(Duration::from_millis(500), |e| matches!(e, Event::Incoming { .. })).await {
            let (theirs, ..) = b.incoming().await;
            let _ = b.node.send(theirs, b"from a node that was disallowed");
            assert!(matches!(b.closed(theirs).await, Closed::ByThem | Closed::LinkLost | Closed::NotAllowed), "round {round}");
        }
        let handed: Vec<Event> = a.drain().await.into_iter().filter(|e| e.as_frame().is_some() || matches!(e, Event::Incoming { .. })).collect();
        assert!(handed.is_empty(), "round {round}: handed over after the disallow: {:?}", handed.iter().map(brief).collect::<Vec<_>>());
        // Allowed again: an open asked now goes.
        a.node.allow(b.id, only(&[0]));
        let ours = a.open(100 + round, b.id, 0, &hint).await.unwrap_or_else(|e| panic!("round {round}: allowed again, the open failed: {e:?}"));
        let (theirs, ..) = b.incoming().await;
        b.node.send(theirs, b"allowed again").unwrap();
        assert_eq!(a.frame(ours).await, b"allowed again");
        a.node.close(ours);
        a.closed(ours).await;
        b.closed(theirs).await;
    }
}

/// The port a node had on a network is its key's, not the node's: another account signed in on the same device (the
/// same Node, another node key) asked for the first account's port, so whoever knew where the first was could tell the
/// second was on the same device. Now each key asks for its own, and the first has its own back.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn another_node_key_on_the_same_node_never_takes_the_port_the_first_had() {
    let home = b"192.168.40.0/24".to_vec();
    let free = |port: u16| std::net::UdpSocket::bind((Ipv4Addr::UNSPECIFIED, port)).is_ok();
    let first = (140..=185u8).find(|n| free(first_port(&[*n; 32], &home))).expect("a key whose port is free");
    let second = (186..=229u8)
        .find(|n| free(first_port(&[*n; 32], &home)) && first_port(&[*n; 32], &home) != first_port(&[first; 32], &home))
        .expect("another key whose port is free");
    let mut a = Dev::new(first);
    a.up_on(&home).await;
    let had = port_of(&a.here().await);
    a.off().await;

    a.secret = [second; 32];
    a.id = node_id(&a.secret);
    a.up_on(&home).await;
    let theirs = port_of(&a.here().await);
    assert_ne!(theirs, had, "the second account's node listens on the first account's port");
    assert_eq!(theirs, first_port(&a.secret, &home));
    a.off().await;

    a.secret = [first; 32];
    a.id = node_id(&a.secret);
    a.up_on(&home).await;
    assert_eq!(port_of(&a.here().await), had, "the first account did not have its own port back");
    a.off().await;
}

/// What is not closed, and cannot be with iroh 1.5 as pinned (README.md, "What a node that links can learn"): a node
/// that links with this one names addresses of its own in QUIC's hole punching (noq's REACH_OUT and ADD_ADDRESS), and
/// this node sends a small probe to each, whatever they are: its own loopback here. noq-proto takes any address there;
/// iroh's transport builder will not turn hole punching off (it ignores fewer than 8 addresses or 9 paths, for the
/// endpoint and for one connection alike) and hands every IP destination to the socket. Run by name; it passes the day
/// this node sends nothing there (`cargo test named_probe -- --ignored`).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "iroh 1.5 has no hook to keep hole punching off an address the other end names"]
async fn a_node_never_sends_a_named_probe_to_its_own_loopback() {
    for allowed in [false, true] {
        let mut b = Dev::new(if allowed { 232 } else { 233 });
        b.up().await;
        let here: SocketAddr = loop {
            let (_, addresses) = b.whereabouts().await;
            if let Some(a) = addresses.iter().filter_map(|a| a.parse::<SocketAddr>().ok()).find(|a| a.is_ipv4()) {
                break a;
            }
        };
        let target = tokio::net::UdpSocket::bind("127.0.0.1:0").await.expect("a socket");
        let named = target.local_addr().expect("its address");
        let key = SecretKey::from_bytes(&[if allowed { 234 } else { 235 }; 32]);
        let other = Endpoint::builder(presets::Minimal)
            .secret_key(key.clone())
            .alpns(vec![ALPN.to_vec()])
            .external_addr(named)
            .bind()
            .await
            .expect("an endpoint");
        if allowed {
            b.node.allow(*key.public().as_bytes(), only(&[0]));
        }
        let conn = other.connect(EndpointAddr::from_parts(EndpointId::from_bytes(&b.id).unwrap(), [TransportAddr::Ip(here)]), ALPN).await;
        let mut buf = [0u8; 2048];
        let got = timeout(Duration::from_secs(10), async {
            loop {
                let (n, from) = target.recv_from(&mut buf).await.expect("recv");
                if from.port() == here.port() {
                    return n;
                }
            }
        })
        .await;
        assert!(got.is_err(), "allowed {allowed}: the node sent {:?} bytes to {named}, which the other end named", got.ok());
        if let Ok(conn) = conn {
            conn.close(0u32.into(), b"");
        }
        other.close().await;
        b.off().await;
    }
}
