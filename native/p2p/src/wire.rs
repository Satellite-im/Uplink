//! What crosses the C interface, as bytes: commands in, events out (README.md has the same tables).
//!
//! Every number is big-endian, a node id is its 32 bytes, text is UTF-8. A command or an event starts with one byte
//! that says which it is. Nothing here is JSON or base64: a frame crosses as it is.
//!
//! Commands come from the app's own Dart, not from another device, but they are read as carefully as if they did
//! not: every length is checked against what is there before anything is taken.

use std::time::Duration;

/// The longest frame a stream carries (`P2pNode.maxFrame`).
pub const MAX_FRAME: usize = 1 << 20;

/// The most link helpers a node is started with, and the longest address of one.
pub const MAX_HELPERS: usize = 8;
pub const MAX_HELPER_LEN: usize = 200;

/// The most addresses a hint or a node's own whereabouts carry, and the longest one (`Whereabouts.mostAddresses`,
/// and the 64 characters `Whereabouts.fromJson` keeps).
pub const MAX_ADDRESSES: usize = 8;
pub const MAX_ADDRESS_LEN: usize = 64;

/// The most streams one TAKEN or DONE names: the Dart side says them once for all it handled of one batch of events.
pub const MAX_LISTED: usize = 4096;

/// The first byte of each command.
pub mod cmd {
    pub const START: u8 = 0x01;
    pub const STOP: u8 = 0x02;
    pub const ALLOW: u8 = 0x03;
    pub const DISALLOW: u8 = 0x04;
    pub const OPEN_TO_ALL: u8 = 0x05;
    pub const OPEN: u8 = 0x06;
    pub const SEND: u8 = 0x07;
    pub const CLOSE: u8 = 0x08;
    pub const TAKEN: u8 = 0x09;
    pub const DONE: u8 = 0x0a;
    pub const NETWORK_CHANGED: u8 = 0x0b;
}

/// The first byte of each event.
pub mod ev {
    pub const UP: u8 = 0x01;
    pub const DOWN: u8 = 0x02;
    pub const OFF: u8 = 0x03;
    pub const WHEREABOUTS: u8 = 0x04;
    pub const PATH: u8 = 0x05;
    pub const OPENED: u8 = 0x06;
    pub const OPEN_FAILED: u8 = 0x07;
    pub const INCOMING: u8 = 0x08;
    pub const FRAME: u8 = 0x09;
    pub const SENT: u8 = 0x0a;
    pub const CLOSED: u8 = 0x0b;
}

/// Where a frame's bytes start in a SEND command (after the kind and the stream), and how long a FRAME event's head is
/// (the kind and the stream: the frame itself is handed over beside it, in a buffer of its own).
pub const FRAME_AT: usize = 9;

/// A set of channels: a channel is one byte on the wire, so any of 256.
#[derive(Clone, Copy, Default, PartialEq, Eq)]
pub struct Channels([u64; 4]);

impl Channels {
    pub const NONE: Channels = Channels([0; 4]);

    /// The set of the channels listed; one named twice is in it once.
    pub fn of(list: &[u8]) -> Self {
        let mut set = Self::NONE;
        for c in list {
            set.0[(*c >> 6) as usize] |= 1u64 << (*c & 63);
        }
        set
    }

    pub fn has(&self, channel: u8) -> bool {
        self.0[(channel >> 6) as usize] & (1u64 << (channel & 63)) != 0
    }

    pub fn is_empty(&self) -> bool {
        self.0 == [0; 4]
    }
}

impl std::fmt::Debug for Channels {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_set().entries((0..=255u8).filter(|c| self.has(*c))).finish()
    }
}

/// What a node is started with (`P2pConfig`).
#[derive(Clone, PartialEq, Eq)]
pub struct Config {
    /// The node key: its id is made from it.
    pub secret: [u8; 32],
    /// The link helpers, as the app wrote them (`https://…`).
    pub helpers: Vec<String>,
    pub helpers_only: bool,
}

impl std::fmt::Debug for Config {
    /// Never the secret.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Config").field("helpers", &self.helpers).field("helpers_only", &self.helpers_only).finish_non_exhaustive()
    }
}

/// The node key is not left behind in memory this library lets go of (zeroize writes it over in a way the compiler
/// keeps). iroh keeps its own copy for as long as the node is up, which it needs.
impl Drop for Config {
    fn drop(&mut self) {
        zeroize::Zeroize::zeroize(&mut self.secret);
    }
}

/// Where another node last said it is (`Whereabouts`), as a dial is given it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Hint {
    pub helper: Option<String>,
    pub addresses: Vec<String>,
}

/// What the app asks of a node, as [`Command::decode`] reads it from the bytes handed to `ghost_p2p_command`.
#[derive(Debug, PartialEq, Eq)]
pub enum Command {
    Start(Config),
    Stop,
    Allow {
        node: [u8; 32],
        channels: Channels,
    },
    Disallow {
        node: [u8; 32],
    },
    OpenToAll {
        channels: Channels,
    },
    Open {
        request: u32,
        node: [u8; 32],
        channel: u8,
        timeout: Duration,
        hint: Hint,
    },
    /// The whole command, the frame from [`FRAME_AT`]: it is sent on without being copied again.
    Send {
        stream: u64,
        len: usize,
    },
    Close {
        stream: u64,
    },
    /// For each stream named, how many of its frames, of how many bytes in all, the app has handed on.
    Taken {
        list: Vec<(u64, u32, u32)>,
    },
    /// The streams whose CLOSED the app has handled.
    Done {
        list: Vec<u64>,
    },
    NetworkChanged,
}

/// Why a command's bytes were not read as a command.
#[derive(Debug, PartialEq, Eq)]
pub enum Malformed {
    /// No bytes at all.
    Empty,
    /// A first byte that is no command's.
    Unknown(u8),
    /// It ends before what it says it holds; or a list that names nothing.
    Short,
    /// Bytes left over after the command.
    Trailing,
    /// More helpers, addresses or streams than a command may name.
    TooMany,
    /// A text or a frame longer than the most.
    TooLong,
    /// Text that is not UTF-8.
    NotText,
}

/// Reads a buffer from the front, never past its end.
struct Reader<'a>(&'a [u8]);

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8], Malformed> {
        if self.0.len() < n {
            return Err(Malformed::Short);
        }
        let (head, rest) = self.0.split_at(n);
        self.0 = rest;
        Ok(head)
    }

    fn u8(&mut self) -> Result<u8, Malformed> {
        Ok(self.take(1)?[0])
    }

    fn u16(&mut self) -> Result<u16, Malformed> {
        Ok(u16::from_be_bytes(self.take(2)?.try_into().expect("two bytes")))
    }

    fn u32(&mut self) -> Result<u32, Malformed> {
        Ok(u32::from_be_bytes(self.take(4)?.try_into().expect("four bytes")))
    }

    fn u64(&mut self) -> Result<u64, Malformed> {
        Ok(u64::from_be_bytes(self.take(8)?.try_into().expect("eight bytes")))
    }

    fn id(&mut self) -> Result<[u8; 32], Malformed> {
        Ok(self.take(32)?.try_into().expect("thirty-two bytes"))
    }

    /// `len` bytes as text, refused before any is taken where `len` is over `most`.
    fn text(&mut self, len: usize, most: usize) -> Result<String, Malformed> {
        if len > most {
            return Err(Malformed::TooLong);
        }
        String::from_utf8(self.take(len)?.to_vec()).map_err(|_| Malformed::NotText)
    }

    /// How many a list names: at least one, at most [`MAX_LISTED`], and no more than the bytes left could hold.
    fn listed(&mut self) -> Result<usize, Malformed> {
        let n = self.u16()? as usize;
        if n == 0 {
            return Err(Malformed::Short);
        }
        if n > MAX_LISTED {
            return Err(Malformed::TooMany);
        }
        Ok(n)
    }

    /// A count in one byte, then that many channels.
    fn channels(&mut self) -> Result<Channels, Malformed> {
        let n = self.u8()? as usize;
        Ok(Channels::of(self.take(n)?))
    }

    /// Refuses a command with anything after it.
    fn end(self) -> Result<(), Malformed> {
        if self.0.is_empty() { Ok(()) } else { Err(Malformed::Trailing) }
    }
}

impl Command {
    /// Reads one whole command, or says what is wrong with it. A SEND's frame is not copied out: it is everything
    /// after the stream, so only its length is checked here.
    pub fn decode(bytes: &[u8]) -> Result<Command, Malformed> {
        let mut r = Reader(bytes);
        let kind = r.u8().map_err(|_| Malformed::Empty)?;
        let command = match kind {
            cmd::START => {
                let helpers_only = r.u8()? != 0;
                let secret = r.id()?;
                let n = r.u8()? as usize;
                if n > MAX_HELPERS {
                    return Err(Malformed::TooMany);
                }
                let mut helpers = Vec::with_capacity(n);
                for _ in 0..n {
                    let len = r.u16()? as usize;
                    helpers.push(r.text(len, MAX_HELPER_LEN)?);
                }
                Command::Start(Config { secret, helpers, helpers_only })
            }
            cmd::STOP => Command::Stop,
            cmd::ALLOW => Command::Allow { node: r.id()?, channels: r.channels()? },
            cmd::DISALLOW => Command::Disallow { node: r.id()? },
            cmd::OPEN_TO_ALL => Command::OpenToAll { channels: r.channels()? },
            cmd::OPEN => {
                let request = r.u32()?;
                let node = r.id()?;
                let channel = r.u8()?;
                let timeout = Duration::from_millis(r.u32()? as u64);
                let helper_len = r.u16()? as usize;
                let helper = r.text(helper_len, MAX_HELPER_LEN)?;
                let n = r.u8()? as usize;
                if n > MAX_ADDRESSES {
                    return Err(Malformed::TooMany);
                }
                let mut addresses = Vec::with_capacity(n);
                for _ in 0..n {
                    let len = r.u8()? as usize;
                    addresses.push(r.text(len, MAX_ADDRESS_LEN)?);
                }
                Command::Open { request, node, channel, timeout, hint: Hint { helper: (!helper.is_empty()).then_some(helper), addresses } }
            }
            cmd::SEND => {
                let stream = r.u64()?;
                let len = r.0.len();
                if len > MAX_FRAME {
                    return Err(Malformed::TooLong);
                }
                return Ok(Command::Send { stream, len });
            }
            cmd::CLOSE => Command::Close { stream: r.u64()? },
            cmd::TAKEN => {
                let n = r.listed()?;
                let mut list = Vec::with_capacity(n);
                for _ in 0..n {
                    list.push((r.u64()?, r.u32()?, r.u32()?));
                }
                Command::Taken { list }
            }
            cmd::DONE => {
                let n = r.listed()?;
                let mut list = Vec::with_capacity(n);
                for _ in 0..n {
                    list.push(r.u64()?);
                }
                Command::Done { list }
            }
            cmd::NETWORK_CHANGED => Command::NetworkChanged,
            other => return Err(Malformed::Unknown(other)),
        };
        r.end()?;
        Ok(command)
    }
}

/// How the path to a linked node stands (`P2pPathKind`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum PathKind {
    None = 0,
    Helper = 1,
    Direct = 2,
}

/// Why a stream could not be opened.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum OpenError {
    /// This node isn't up.
    NotUp = 1,
    /// It could not be reached in time: no address that answers, or no link helper both are on.
    Unreachable = 2,
    /// It turned this node away: it has not allowed it.
    TurnedAway = 3,
    /// It is allowed, but not on this channel.
    Refused = 4,
    /// What was asked makes no sense (a node dialling itself, an id that is no key).
    BadRequest = 5,
    /// The link is up and already carries as many of this node's streams as a link does.
    TooMany = 6,
}

/// Why a stream closed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Closed {
    /// This end closed it, and the other end saw the end of it (or was given a few seconds to).
    ByUs = 0,
    /// The other end closed it.
    ByThem = 1,
    /// The link went: the other device left, or the network did.
    LinkLost = 2,
    /// This node stopped.
    Stopped = 3,
    /// The other node is no longer allowed here (`disallow`, or `allow` with fewer channels).
    NotAllowed = 4,
    /// More was sent than the stream's queue holds: closed, not grown.
    Overflow = 5,
    /// The other end sent what is no frame: longer than the most, cut short, or left half-sent.
    Broken = 6,
}

/// What a node tells the app. Each is one buffer handed to the callback.
#[derive(Debug, PartialEq, Eq)]
pub enum Event {
    Up {
        node: [u8; 32],
    },
    Down {
        problem: String,
    },
    Off,
    Whereabouts {
        helper: Option<String>,
        addresses: Vec<String>,
    },
    Path {
        node: [u8; 32],
        kind: PathKind,
        rtt_ms: Option<u32>,
    },
    Opened {
        request: u32,
        stream: u64,
    },
    OpenFailed {
        request: u32,
        why: OpenError,
        message: String,
    },
    Incoming {
        stream: u64,
        node: [u8; 32],
        channel: u8,
    },
    /// A frame, read off the network straight into the buffer it is handed over in.
    Frame {
        stream: u64,
        frame: Vec<u8>,
    },
    Sent {
        stream: u64,
        frames: u64,
    },
    Closed {
        stream: u64,
        why: Closed,
    },
}

impl Event {
    /// A FRAME event's head: the kind and the stream. The frame goes beside it, as a buffer of its own.
    pub fn frame_head(stream: u64) -> [u8; FRAME_AT] {
        let mut head = [0u8; FRAME_AT];
        head[0] = ev::FRAME;
        head[1..].copy_from_slice(&stream.to_be_bytes());
        head
    }

    /// The stream and the frame of a FRAME event.
    pub fn as_frame(&self) -> Option<(u64, &[u8])> {
        match self {
            Event::Frame { stream, frame } => Some((*stream, frame)),
            _ => None,
        }
    }

    /// The event as the app is handed it: its bytes, and for a FRAME, the frame beside them.
    pub fn encode(self) -> (Vec<u8>, Option<Vec<u8>>) {
        match self {
            Event::Frame { stream, frame } => (Self::frame_head(stream).to_vec(), Some(frame)),
            other => (other.encode_head(), None),
        }
    }

    /// Every event but a FRAME, as its bytes.
    fn encode_head(self) -> Vec<u8> {
        match self {
            Event::Frame { stream, .. } => Self::frame_head(stream).to_vec(),
            Event::Up { node } => [&[ev::UP][..], &node].concat(),
            Event::Down { problem } => [&[ev::DOWN][..], problem.as_bytes()].concat(),
            Event::Off => vec![ev::OFF],
            Event::Whereabouts { helper, addresses } => {
                let helper = helper.unwrap_or_default();
                let mut b = vec![ev::WHEREABOUTS];
                b.extend_from_slice(&(helper.len().min(u16::MAX as usize) as u16).to_be_bytes());
                b.extend_from_slice(&helper.as_bytes()[..helper.len().min(u16::MAX as usize)]);
                let list: Vec<&String> = addresses.iter().filter(|a| a.len() <= MAX_ADDRESS_LEN).take(MAX_ADDRESSES).collect();
                b.push(list.len() as u8);
                for a in list {
                    b.push(a.len() as u8);
                    b.extend_from_slice(a.as_bytes());
                }
                b
            }
            Event::Path { node, kind, rtt_ms } => {
                let mut b = vec![ev::PATH];
                b.extend_from_slice(&node);
                b.push(kind as u8);
                // A round trip not yet known is all ones, which no known one is ever written as.
                b.extend_from_slice(&rtt_ms.map(|ms| ms.min(u32::MAX - 1)).unwrap_or(u32::MAX).to_be_bytes());
                b
            }
            Event::Opened { request, stream } => [&[ev::OPENED][..], &request.to_be_bytes(), &stream.to_be_bytes()].concat(),
            Event::OpenFailed { request, why, message } => {
                [&[ev::OPEN_FAILED][..], &request.to_be_bytes(), &[why as u8], message.as_bytes()].concat()
            }
            Event::Incoming { stream, node, channel } => [&[ev::INCOMING][..], &stream.to_be_bytes(), &node, &[channel]].concat(),
            Event::Sent { stream, frames } => [&[ev::SENT][..], &stream.to_be_bytes(), &frames.to_be_bytes()].concat(),
            Event::Closed { stream, why } => [&[ev::CLOSED][..], &stream.to_be_bytes(), &[why as u8]].concat(),
        }
    }
}

/// 64 hex digits, lower case, for a node id.
pub fn hex(id: &[u8; 32]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(64);
    for b in id {
        s.push(DIGITS[(b >> 4) as usize] as char);
        s.push(DIGITS[(b & 15) as usize] as char);
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A START command's bytes, with a key of all sevens.
    fn start(helpers: &[&str], helpers_only: bool) -> Vec<u8> {
        let mut b = vec![cmd::START, helpers_only as u8];
        b.extend_from_slice(&[7u8; 32]);
        b.push(helpers.len() as u8);
        for h in helpers {
            b.extend_from_slice(&(h.len() as u16).to_be_bytes());
            b.extend_from_slice(h.as_bytes());
        }
        b
    }

    #[test]
    fn a_start_is_read_whole() {
        let c = Command::decode(&start(&["https://link.example", "https://two.example"], true)).unwrap();
        assert_eq!(
            c,
            Command::Start(Config {
                secret: [7; 32],
                helpers: vec!["https://link.example".into(), "https://two.example".into()],
                helpers_only: true
            })
        );
        assert_eq!(Command::decode(&start(&[], false)).unwrap(), Command::Start(Config { secret: [7; 32], helpers: vec![], helpers_only: false }));
    }

    #[test]
    fn every_cut_of_every_command_is_refused_not_read_past() {
        let mut open = vec![cmd::OPEN, 0, 0, 0, 9];
        open.extend_from_slice(&[3u8; 32]);
        open.push(1);
        open.extend_from_slice(&5000u32.to_be_bytes());
        open.extend_from_slice(&20u16.to_be_bytes());
        open.extend_from_slice(b"https://link.example");
        open.push(2);
        open.push(14);
        open.extend_from_slice(b"127.0.0.1:4433");
        open.push(8);
        open.extend_from_slice(b"[::1]:99");
        let mut allow = vec![cmd::ALLOW];
        allow.extend_from_slice(&[4u8; 32]);
        allow.extend_from_slice(&[2, 0, 2]);
        let whole: Vec<Vec<u8>> = vec![
            start(&["https://link.example"], false),
            open.clone(),
            allow,
            [&[cmd::DISALLOW][..], &[5u8; 32]].concat(),
            vec![cmd::OPEN_TO_ALL, 1, 1],
            [&[cmd::CLOSE][..], &9u64.to_be_bytes()].concat(),
            [&[cmd::TAKEN, 0, 1][..], &9u64.to_be_bytes(), &1u32.to_be_bytes(), &2u32.to_be_bytes()].concat(),
            [
                &[cmd::TAKEN, 0, 2][..],
                &9u64.to_be_bytes(),
                &1u32.to_be_bytes(),
                &2u32.to_be_bytes(),
                &8u64.to_be_bytes(),
                &3u32.to_be_bytes(),
                &4u32.to_be_bytes(),
            ]
            .concat(),
            [&[cmd::DONE, 0, 1][..], &9u64.to_be_bytes()].concat(),
            [&[cmd::DONE, 0, 2][..], &9u64.to_be_bytes(), &10u64.to_be_bytes()].concat(),
        ];
        for bytes in &whole {
            assert!(Command::decode(bytes).is_ok(), "{bytes:?}");
            for cut in 0..bytes.len() {
                assert!(Command::decode(&bytes[..cut]).is_err(), "cut at {cut} of {bytes:?}");
            }
            let mut more = bytes.clone();
            more.push(0);
            assert_eq!(Command::decode(&more), Err(Malformed::Trailing), "{bytes:?}");
        }
        assert_eq!(
            Command::decode(&open).unwrap(),
            Command::Open {
                request: 9,
                node: [3; 32],
                channel: 1,
                timeout: Duration::from_secs(5),
                hint: Hint { helper: Some("https://link.example".into()), addresses: vec!["127.0.0.1:4433".into(), "[::1]:99".into()] },
            }
        );
        assert_eq!(Command::decode(&[]), Err(Malformed::Empty));
        assert_eq!(Command::decode(&[0x7f]), Err(Malformed::Unknown(0x7f)));
        // A list of streams is read whole, and says how long it is: never none, never more than are allowed.
        assert_eq!(
            Command::decode(
                &[
                    &[cmd::TAKEN, 0, 2][..],
                    &9u64.to_be_bytes(),
                    &1u32.to_be_bytes(),
                    &2u32.to_be_bytes(),
                    &8u64.to_be_bytes(),
                    &3u32.to_be_bytes(),
                    &4u32.to_be_bytes()
                ]
                .concat()
            ),
            Ok(Command::Taken { list: vec![(9, 1, 2), (8, 3, 4)] })
        );
        assert_eq!(
            Command::decode(&[&[cmd::DONE, 0, 2][..], &9u64.to_be_bytes(), &10u64.to_be_bytes()].concat()),
            Ok(Command::Done { list: vec![9, 10] })
        );
        assert_eq!(Command::decode(&[cmd::TAKEN, 0, 0]), Err(Malformed::Short));
        assert_eq!(Command::decode(&[cmd::DONE, 0, 0]), Err(Malformed::Short));
        let mut many = vec![cmd::DONE];
        many.extend_from_slice(&((MAX_LISTED + 1) as u16).to_be_bytes());
        many.resize(3 + (MAX_LISTED + 1) * 8, 0);
        assert_eq!(Command::decode(&many), Err(Malformed::TooMany));
    }

    #[test]
    fn too_many_and_too_long_are_refused() {
        let nine: Vec<&str> = vec!["https://a.example"; MAX_HELPERS + 1];
        assert_eq!(Command::decode(&start(&nine, false)), Err(Malformed::TooMany));
        let long = format!("https://{}.example", "a".repeat(MAX_HELPER_LEN));
        assert_eq!(Command::decode(&start(&[&long], false)), Err(Malformed::TooLong));
        let mut send = vec![cmd::SEND];
        send.extend_from_slice(&1u64.to_be_bytes());
        send.resize(FRAME_AT + MAX_FRAME, 0);
        assert_eq!(Command::decode(&send), Ok(Command::Send { stream: 1, len: MAX_FRAME }));
        send.push(0);
        assert_eq!(Command::decode(&send), Err(Malformed::TooLong));
        assert_eq!(Command::decode(&send[..FRAME_AT]), Ok(Command::Send { stream: 1, len: 0 }));
        let mut bad = start(&["https://link.example"], false);
        let at = bad.len() - 3;
        bad[at] = 0xff;
        assert_eq!(Command::decode(&bad), Err(Malformed::NotText));
    }

    #[test]
    fn channels_are_a_set() {
        let set = Channels::of(&[0, 2, 255, 2]);
        assert!(set.has(0) && set.has(2) && set.has(255));
        assert!(!set.has(1) && !set.has(64) && !set.has(254));
        assert!(Channels::NONE.is_empty() && !set.is_empty());
        assert_eq!(format!("{set:?}"), "{0, 2, 255}");
    }

    /// An event's bytes, where it is not a frame.
    fn bytes(event: Event) -> Vec<u8> {
        let (head, frame) = event.encode();
        assert!(frame.is_none());
        head
    }

    #[test]
    fn events_are_laid_out_as_the_readme_says() {
        assert_eq!(bytes(Event::Up { node: [1; 32] }), [&[ev::UP][..], &[1u8; 32]].concat());
        assert_eq!(bytes(Event::Down { problem: "no".into() }), vec![ev::DOWN, b'n', b'o']);
        assert_eq!(bytes(Event::Off), vec![ev::OFF]);
        assert_eq!(
            bytes(Event::Whereabouts { helper: Some("https://h".into()), addresses: vec!["1.2.3.4:5".into()] }),
            [&[ev::WHEREABOUTS, 0, 9][..], b"https://h", &[1, 9], b"1.2.3.4:5"].concat()
        );
        assert_eq!(bytes(Event::Whereabouts { helper: None, addresses: vec![] }), vec![ev::WHEREABOUTS, 0, 0, 0]);
        assert_eq!(
            bytes(Event::Path { node: [2; 32], kind: PathKind::Direct, rtt_ms: Some(7) }),
            [&[ev::PATH][..], &[2u8; 32], &[2, 0, 0, 0, 7]].concat()
        );
        assert_eq!(
            bytes(Event::Path { node: [2; 32], kind: PathKind::None, rtt_ms: None }),
            [&[ev::PATH][..], &[2u8; 32], &[0, 255, 255, 255, 255]].concat()
        );
        assert_eq!(bytes(Event::Opened { request: 3, stream: 4 }), vec![ev::OPENED, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 4]);
        assert_eq!(
            bytes(Event::OpenFailed { request: 3, why: OpenError::TurnedAway, message: "x".into() }),
            vec![ev::OPEN_FAILED, 0, 0, 0, 3, 3, b'x']
        );
        assert_eq!(
            bytes(Event::Incoming { stream: 5, node: [9; 32], channel: 1 }),
            [&[ev::INCOMING, 0, 0, 0, 0, 0, 0, 0, 5][..], &[9u8; 32], &[1]].concat()
        );
        // A frame is its head, and the frame itself beside it in a buffer of its own.
        let frame = Event::Frame { stream: 6, frame: b"abc".to_vec() };
        assert_eq!(frame.as_frame(), Some((6, &b"abc"[..])));
        assert_eq!(frame.encode(), (vec![ev::FRAME, 0, 0, 0, 0, 0, 0, 0, 6], Some(b"abc".to_vec())));
        assert_eq!(bytes(Event::Sent { stream: 6, frames: 258 }), vec![ev::SENT, 0, 0, 0, 0, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 1, 2]);
        assert_eq!(bytes(Event::Closed { stream: 6, why: Closed::Overflow }), vec![ev::CLOSED, 0, 0, 0, 0, 0, 0, 0, 6, 5]);
    }

    #[test]
    fn whereabouts_never_say_more_than_the_app_keeps() {
        let many: Vec<String> = (0..20).map(|i| format!("10.0.0.{i}:1")).collect();
        let said = bytes(Event::Whereabouts { helper: None, addresses: many });
        assert_eq!(said[3] as usize, MAX_ADDRESSES);
        let long = bytes(Event::Whereabouts { helper: None, addresses: vec!["x".repeat(MAX_ADDRESS_LEN + 1), "1.1.1.1:1".into()] });
        assert_eq!(long[3], 1);
    }

    #[test]
    fn a_node_id_is_64_hex_digits() {
        let mut id = [0u8; 32];
        id[0] = 0xab;
        id[31] = 0x0f;
        let s = hex(&id);
        assert_eq!(s.len(), 64);
        assert!(s.starts_with("ab00") && s.ends_with("000f"));
    }
}
