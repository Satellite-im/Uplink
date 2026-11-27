//! Proves a link helper links two devices (docs/OPEN_NETWORK.md section 2; docs/SELF_HOSTING.md, "A link helper for
//! direct links"). A link helper is iroh's relay server: devices on the direct network find each other through it,
//! and fall back on it when no straight path can be made. tool/build-link.sh builds it, tool/deploy-link.mjs puts
//! ours on the box.
//!
//!   cargo run                             starts build/link/host/iroh-relay on this machine as relay/deploy's
//!                                         samples have it started (link-helper.toml.example's settings,
//!                                         ghost-link.service's environment), with a certificate made for the run,
//!                                         and checks it
//!   cargo run -- https://gogho.st:7843    checks a helper that is running somewhere (--quic <port> where its QUIC
//!                                         address discovery is not on 7842; --token <token> where it asks for one;
//!                                         --root <file> to believe only that certificate, DER, in place of the
//!                                         web's authorities)
//!   cargo test                            the first of those, as a test
//!
//! What is checked, with iroh endpoints made as the app's direct network makes them: no address lookup of any kind,
//! and the helper as their only relay.
//!   1. Two devices sign in to the helper, and it tells each the address it is seen at (QUIC address discovery).
//!      One is given only the other's id and the helper's address. They link, pass frames both ways, and the path
//!      in use is said: through the helper at first, then straight where a straight path can be made.
//!   2. The same with one device's IP transports cleared, so it can reach nothing but the helper. Every byte then
//!      goes through the helper, two megabytes of them at the end, which is where a limit per device shows.
//!   3. Only with a helper started here: one that asks for a token turns away a device without it and takes one
//!      with it. That is how ours could be closed to strangers later (the app would be handed the token by its
//!      relay); it is not how ours runs.
//!
//! Started here, the helper is also asked what it counted (its own metrics), is stopped the way its service stops
//! it (SIGINT, by its process id), and what it wrote is read for any device's id, which the service's settings are
//! meant to keep out of the journal. The check passes only if all of it held.

use std::{
    env, fs,
    net::{SocketAddr, TcpListener, UdpSocket},
    path::{Path, PathBuf},
    process::{Child, Command, ExitCode, Stdio},
    time::{Duration, Instant},
};

use iroh::{
    Endpoint, EndpointAddr, RelayConfig, RelayMap, RelayMode, RelayUrl, SecretKey, Watcher,
    endpoint::{Connection, RecvStream, SendStream, presets},
    tls::CaTlsConfig,
};
use iroh_relay::RelayQuicConfig;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
    time::{sleep, timeout},
};

/// A result whose error is only ever printed, as the line that says what did not hold.
type Res<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

/// What the two devices speak to each other here. Nothing else speaks it.
const ALPN: &[u8] = b"ghost/link-check/0";
/// How many small frames go each way, twice over in the first step.
const FRAMES: usize = 5;
/// The load that shows a limit: more than a helper lets one device send at once.
const LOAD: usize = 2 * 1024 * 1024;
/// Where iroh's relay server answers QUIC address discovery unless told otherwise, and where an app that is handed
/// only an https address looks for it.
const QUIC: u16 = 7842;

/// A link helper, as a device is told of it.
#[derive(Clone)]
struct Helper {
    url: RelayUrl,
    quic: u16,
    /// The one certificate to believe, where the helper's was made for this run (DER). Otherwise the web's own.
    root: Option<Vec<u8>>,
    token: Option<String>,
}

#[tokio::main]
async fn main() -> ExitCode {
    match run(env::args().skip(1).collect()).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(why) => {
            println!("x {why}");
            ExitCode::FAILURE
        }
    }
}

/// Reads the arguments and runs the proof they ask for: against the helper at the address given, or with no
/// address against one started on this machine (`--helper` says which program).
async fn run(args: Vec<String>) -> Res<()> {
    let mut url = None;
    let mut quic = QUIC;
    let mut token = None;
    let mut root = None;
    let mut program = None;
    let mut args = args.into_iter();
    while let Some(arg) = args.next() {
        let mut value = |name: &str| args.next().ok_or(format!("{name} needs a value"));
        match arg.as_str() {
            "--quic" => quic = value("--quic")?.parse().map_err(|_| "--quic takes a port")?,
            "--token" => token = Some(value("--token")?),
            "--root" => {
                let file = value("--root")?;
                root = Some(fs::read(&file).map_err(|e| format!("{file}: {e}"))?);
            }
            "--helper" => program = Some(PathBuf::from(value("--helper")?)),
            "-h" | "--help" => {
                println!("cargo run [-- <the helper's https address> [--quic <port>] [--token <token>] [--root <certificate.der>]]\ncargo run [-- --helper <an iroh-relay built for this machine>]");
                return Ok(());
            }
            other if url.is_none() && !other.starts_with('-') => url = Some(other.to_string()),
            other => return Err(format!("{other}: not something this takes (--help says what is)").into()),
        }
    }
    match url {
        Some(url) => {
            let url: RelayUrl = url.parse().map_err(|_| format!("{url} is not an address (https://host or https://host:port)"))?;
            if url.scheme() != "https" {
                return Err(format!("{url}: a link helper is reached by https").into());
            }
            println!("> the link helper at {url}, QUIC address discovery on UDP {quic}{}", if token.is_some() { ", with a token" } else { "" });
            let problems = check(&Helper { url, quic, root, token }, None).await?;
            done(problems)
        }
        None => local(program).await,
    }
}

/// Prints each check that did not hold, and fails if there was one.
fn done(problems: Vec<String>) -> Res<()> {
    if problems.is_empty() {
        println!("ok all of it held");
        return Ok(());
    }
    for problem in &problems {
        println!("x {problem}");
    }
    Err(format!("{} of the checks did not hold", problems.len()).into())
}

/// The whole proof against a helper started here.
async fn local(program: Option<PathBuf>) -> Res<()> {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let program = program.unwrap_or_else(|| root.join("build/link/host/iroh-relay"));
    let sample = root.join("relay/deploy");
    let started = Started::start(&program, &sample, None)?;
    println!(
        "> a link helper started here (process {}): {}, QUIC address discovery on UDP {}, the sample settings and the sample service's environment, a certificate made for this run",
        started.child.id(),
        started.helper.url,
        started.helper.quic
    );
    let mut problems = Vec::new();
    // The plain-HTTP door the settings keep to this machine: there, and answering as the server means it to.
    match get(started.plain, "/generate_204").await {
        Ok((204, _)) => println!("ok its plain-HTTP door is where the settings put it ({})", started.plain),
        other => problems.push(format!("its plain-HTTP door at {} did not answer 204 to /generate_204 ({other:?})", started.plain)),
    }
    problems.extend(check(&started.helper, Some(&started)).await?);

    println!("> 3. a helper that asks for a token (how ours could be closed to strangers later; not how it runs)");
    let token: String = SecretKey::generate().to_bytes().iter().map(|b| format!("{b:02x}")).collect();
    let closed = Started::start(&program, &sample, Some(&token))?;
    let without = device(&closed.helper, true).await?;
    match timeout(Duration::from_secs(10), refused(&without)).await {
        Ok(reason) => println!("ok a device without the token is turned away ({reason})"),
        Err(_) if without.home_relay_status().get().iter().any(|s| s.is_connected()) => problems.push("a device without the token was let in".into()),
        Err(_) => problems.push("a device without the token was neither let in nor told it was refused, in 10 s".into()),
    }
    without.close().await;
    let with = device(&Helper { token: Some(token), ..closed.helper.clone() }, true).await?;
    match signed_in(&with, Instant::now(), "a device with the token").await {
        Ok(took) => println!("ok a device with the token signs in ({})", ms(took)),
        Err(why) => problems.push(why.to_string()),
    }
    with.close().await;
    closed.stop()?;

    let wrote = started.wrote();
    match started.stop() {
        Ok(how) => println!("ok the first helper stopped on SIGINT, as its service stops it ({how})"),
        Err(why) => problems.push(why.to_string()),
    }
    println!("  what it wrote over the whole run, with the service's environment ({} lines):", wrote.lines().count());
    for line in wrote.lines() {
        println!("    {line}");
    }
    // iroh-relay names a device in what it writes as remote_endpoint=<the start of its id>.
    if wrote.contains("remote_endpoint") || wrote.contains("endpoint_id") {
        problems.push("the helper wrote of a device by its id: the service's RUST_LOG is meant to keep that out of the journal".into());
    } else {
        println!("ok nothing it wrote names a device");
    }
    done(problems)
}

/// Steps 1 and 2 against a helper, wherever it is. What stops everything is an error; what merely did not hold is
/// handed back, so one run says all of it.
async fn check(helper: &Helper, started: Option<&Started>) -> Res<Vec<String>> {
    let mut problems = Vec::new();

    // Is anything there at all? Asked first, so that a closed port is not taken further down for a helper that
    // turns devices away.
    let (host, port) = (helper.url.host_str().unwrap_or_default().to_string(), helper.url.port_or_known_default().unwrap_or(443));
    match timeout(Duration::from_secs(8), TcpStream::connect((host.as_str(), port))).await {
        Ok(Ok(_)) => {}
        Ok(Err(why)) => return Err(format!("nothing takes a connection at {host}:{port} ({why}): no helper is running there, or a firewall keeps TCP {port} out").into()),
        Err(_) => return Err(format!("nothing answered at {host}:{port} in 8 s: no helper is running there, or a firewall keeps TCP {port} out").into()),
    }

    println!("> 1. two devices with no address lookup of any kind, and this helper as their only one");
    let made = Instant::now();
    let (a, b) = (device(helper, true).await?, device(helper, true).await?);
    let (took_a, took_b) = (signed_in(&a, made, "the first device").await?, signed_in(&b, made, "the second device").await?);
    println!("ok both signed in to the helper ({} and {} after they were made)", ms(took_a), ms(took_b));
    match seen_at(&a).await {
        Some((addr, how)) => println!("ok the helper told the first device where it is seen: {addr} ({how})"),
        None => problems.push(format!("the helper never told a device where it is seen: nothing answers QUIC address discovery on UDP {}", helper.quic)),
    }
    if let Some(Some(true)) = a.net_report().get().map(|r| r.captive_portal) {
        println!("  iroh's captive-portal check says \"captive portal\": it asks port 80 of the helper's name, which is not this helper's. The app's core should make its endpoints with that check off (NetReportConfig::captive_portal_check).");
    }
    let began = Instant::now();
    let (ours, theirs, took) = link(&a, &b, helper).await?;
    let first = paths(&ours);
    let answering = tokio::spawn(answer(theirs));
    let (mut tx, mut rx) = ours.open_bi().await?;
    let trip = frames(&mut tx, &mut rx).await?;
    println!("ok linked in {}, given only the other's id and the helper's address; {FRAMES} frames each way, {} a round trip at most", ms(took), ms(trip));
    println!("  the path at first: {}", said(&first));
    match straight(&ours, Duration::from_secs(10)).await {
        Some(addr) => {
            let after = began.elapsed();
            let trip = frames(&mut tx, &mut rx).await?;
            println!("ok a straight path was made and chosen {} after dialling ({addr}); {FRAMES} more frames each way, {} a round trip at most", ms(after), ms(trip));
        }
        None => println!("  no straight path was chosen in 10 s: these two devices stay on the helper (not a fault of the helper's: it is what a network that lets none be made looks like)"),
    }
    println!("  the paths now: {}", said(&paths(&ours)));
    hang_up(ours, tx, answering).await?;
    a.close().await;
    b.close().await;

    println!("> 2. the same, the second device with its IP transports cleared: it can reach nothing but the helper");
    let before = match started {
        Some(started) => Some(started.counted().await?),
        None => None,
    };
    let made = Instant::now();
    let (a, b) = (device(helper, true).await?, device(helper, false).await?);
    signed_in(&a, made, "the first device").await?;
    signed_in(&b, made, "the second device").await?;
    let (ours, theirs, took) = link(&a, &b, helper).await?;
    let far = theirs.clone();
    let answering = tokio::spawn(answer(theirs));
    let (mut tx, mut rx) = ours.open_bi().await?;
    let trip = frames(&mut tx, &mut rx).await?;
    println!("ok linked in {}; {FRAMES} frames each way, {} a round trip at most", ms(took), ms(trip));
    let began = Instant::now();
    let load: Vec<u8> = (0..LOAD).map(|i| (i % 251) as u8).collect();
    write_frame(&mut tx, &load).await?;
    let reply = timeout(Duration::from_secs(120), read_frame(&mut rx)).await.map_err(|_| "the load was not answered in two minutes")??;
    let took = began.elapsed();
    if reply != reply_to(&load) {
        problems.push("the load did not arrive as it was sent".into());
    }
    let rate = LOAD as f64 / 1024.0 / took.as_secs_f64();
    println!("ok {} KiB through the helper and answered in {:.1} s ({rate:.0} KiB a second over all of it)", LOAD / 1024, took.as_secs_f64());
    // Long enough for a straight path to have been made, had there been any way to make one.
    sleep(Duration::from_secs(2)).await;
    let (near, far) = (paths(&ours), paths(&far));
    println!("  the paths, as the second device has them: {}", said(&near));
    println!("  the paths, as the first device has them: {}", said(&far));
    if near.iter().chain(&far).any(|p| !p.helper) || !near.iter().any(|p| p.helper && p.chosen) {
        problems.push("with IP transports cleared on one side there was still a path that is not the helper's".into());
    } else {
        println!("ok every path is the helper's, on both sides");
    }
    hang_up(ours, tx, answering).await?;
    a.close().await;
    b.close().await;

    if let (Some(started), Some(before)) = (started, before) {
        let after = started.counted().await?;
        let (took_in, gave_out) = (after.bytes_in - before.bytes_in, after.bytes_out - before.bytes_out);
        if took_in < LOAD as u64 || gave_out < LOAD as u64 {
            problems.push(format!("the helper counted {took_in} bytes in and {gave_out} out over step 2, less than the {LOAD} that were sent"));
        } else {
            println!("ok the helper's own count over step 2: {} KiB taken in, {} KiB handed on, {} devices signed in so far", took_in / 1024, gave_out / 1024, after.signed_in);
        }
        if let Some((a_second, at_once)) = started.limit {
            // What the settings allow: the first `at_once` bytes as they come, the rest at `a_second`.
            let least = (LOAD as u64).saturating_sub(at_once) as f64 / a_second as f64;
            let slowed = after.slowed - before.slowed;
            if took.as_secs_f64() < least * 0.8 || slowed == 0 {
                problems.push(format!("the limit in the settings did not hold: the load took {:.1} s where it allows no less than {least:.1} s, and the helper counted {slowed} devices slowed", took.as_secs_f64()));
            } else {
                println!("ok the limit in the settings held: {} KiB at once and {} KiB a second allow the load no less than {least:.1} s, and the helper counted {slowed} device slowed", at_once / 1024, a_second / 1024);
            }
        }
    }
    Ok(problems)
}

/// A device as the app's direct network makes one: nothing looks its address up or publishes it (`presets::Minimal`
/// sets no address lookup at all), and the helper is its only relay. `straight` false clears its IP transports.
async fn device(helper: &Helper, straight: bool) -> Res<Endpoint> {
    let mut relay = RelayConfig::new(helper.url.clone(), Some(RelayQuicConfig::new(helper.quic)));
    if let Some(token) = &helper.token {
        relay = relay.with_auth_token(token.clone());
    }
    let mut builder = Endpoint::builder(presets::Minimal).relay_mode(RelayMode::Custom(RelayMap::from(relay))).alpns(vec![ALPN.to_vec()]);
    if let Some(root) = &helper.root {
        builder = builder.ca_tls_config(CaTlsConfig::custom_roots([root.clone().into()]));
    }
    if !straight {
        builder = builder.clear_ip_transports();
    }
    builder.bind().await.map_err(|e| format!("a device could not be made: {e:#}").into())
}

/// How long after it was made a device had signed in to the helper.
async fn signed_in(device: &Endpoint, made: Instant, who: &str) -> Res<Duration> {
    if timeout(Duration::from_secs(15), device.online()).await.is_err() {
        let status = device.home_relay_status().get();
        let why = status
            .iter()
            .find_map(|s| s.auth_denied_reason().map(|r| format!("the helper refused it ({r})")))
            .or_else(|| status.iter().find_map(|s| s.last_error().map(|e| format!("{e:#}"))))
            .unwrap_or_else(|| "something takes connections there, and iroh gave no reason. A certificate the device does not believe looks like this, and so does a server that is not a link helper".into());
        return Err(format!("{who} did not sign in to the helper in 15 s: {why}").into());
    }
    Ok(made.elapsed())
}

/// Waits until the helper has told a device it is refused, and gives the helper's word for it.
async fn refused(device: &Endpoint) -> String {
    let mut status = device.home_relay_status();
    loop {
        if let Some(reason) = status.get().iter().find_map(|s| s.auth_denied_reason().map(str::to_string)) {
            return reason;
        }
        if status.updated().await.is_err() {
            std::future::pending::<()>().await;
        }
    }
}

/// The address the helper told a device it is seen at, and by which probes the helper was timed.
async fn seen_at(device: &Endpoint) -> Option<(SocketAddr, String)> {
    let mut reports = device.net_report();
    timeout(Duration::from_secs(12), async {
        loop {
            if let Some(report) = reports.get() {
                let addr = report.global_v4.map(SocketAddr::V4).or(report.global_v6.map(SocketAddr::V6));
                if let Some(addr) = addr {
                    let timed: Vec<String> = report.relay_latency.iter().map(|(probe, _, took)| format!("{probe} {}", ms(took))).collect();
                    return Some((addr, timed.join(", ")));
                }
            }
            if reports.updated().await.is_err() {
                return None;
            }
        }
    })
    .await
    .ok()
    .flatten()
}

/// Links `b` to `a`, `b` knowing only `a`'s id and the helper's address. Both ends of the link, and how long it took.
async fn link(a: &Endpoint, b: &Endpoint, helper: &Helper) -> Res<(Connection, Connection, Duration)> {
    let host = a.clone();
    let accepting = tokio::spawn(async move {
        let incoming = host.accept().await.ok_or_else(|| "the first device stopped listening".to_string())?;
        incoming.await.map_err(|e| format!("the first device could not take the link: {e:#}"))
    });
    let began = Instant::now();
    let to = EndpointAddr::new(a.id()).with_relay_url(helper.url.clone());
    let ours = timeout(Duration::from_secs(20), b.connect(to, ALPN)).await.map_err(|_| "no link in 20 s")?.map_err(|e| format!("no link: {e:#}"))?;
    let took = began.elapsed();
    let theirs = timeout(Duration::from_secs(5), accepting).await.map_err(|_| "the first device never took the link")???;
    Ok((ours, theirs, took))
}

/// The far end of a link: answers each frame with one of its own, until an empty one says that is all.
async fn answer(link: Connection) -> Res<()> {
    let (mut tx, mut rx) = link.accept_bi().await?;
    loop {
        let frame = read_frame(&mut rx).await?;
        if frame.is_empty() {
            break;
        }
        write_frame(&mut tx, &reply_to(&frame)).await?;
    }
    tx.finish()?;
    link.closed().await;
    Ok(())
}

/// A small frame comes back turned round; a load comes back as its length and the sum of its bytes.
fn reply_to(frame: &[u8]) -> Vec<u8> {
    if frame.len() <= 64 * 1024 {
        return frame.iter().rev().copied().collect();
    }
    let sum: u64 = frame.iter().map(|b| u64::from(*b)).sum();
    [(frame.len() as u64).to_be_bytes(), sum.to_be_bytes()].concat()
}

/// `FRAMES` frames out and their answers back; the longest any round trip took.
async fn frames(tx: &mut SendStream, rx: &mut RecvStream) -> Res<Duration> {
    let mut longest = Duration::ZERO;
    for n in 0..FRAMES {
        let frame: Vec<u8> = (0..1024).map(|i| ((i + n * 7) % 256) as u8).collect();
        let began = Instant::now();
        write_frame(tx, &frame).await?;
        let reply = timeout(Duration::from_secs(20), read_frame(rx)).await.map_err(|_| "a frame was not answered in 20 s")??;
        longest = longest.max(began.elapsed());
        if reply != reply_to(&frame) {
            return Err("a frame came back as something else".into());
        }
    }
    Ok(longest)
}

/// A frame on the stream: its length in four bytes, big-endian, then its bytes.
async fn write_frame(tx: &mut SendStream, frame: &[u8]) -> Res<()> {
    tx.write_all(&(frame.len() as u32).to_be_bytes()).await?;
    tx.write_all(frame).await?;
    Ok(())
}

/// The next frame off the stream; one longer than anything sent here is refused before room is made for it.
async fn read_frame(rx: &mut RecvStream) -> Res<Vec<u8>> {
    let mut length = [0u8; 4];
    rx.read_exact(&mut length).await?;
    let length = u32::from_be_bytes(length) as usize;
    if length > 2 * LOAD {
        return Err(format!("a frame of {length} bytes: nothing here sends one").into());
    }
    let mut frame = vec![0u8; length];
    rx.read_exact(&mut frame).await?;
    Ok(frame)
}

/// Says that is all, and waits for the far end to have heard it before the link is closed.
async fn hang_up(link: Connection, mut tx: SendStream, answering: tokio::task::JoinHandle<Res<()>>) -> Res<()> {
    write_frame(&mut tx, &[]).await?;
    tx.finish()?;
    // The far end closes its half once it has read the empty frame: that it stopped is the proof it arrived.
    let _ = timeout(Duration::from_secs(5), tx.stopped()).await;
    link.close(0u32.into(), b"done");
    match timeout(Duration::from_secs(5), answering).await {
        Ok(Ok(Ok(()))) => Ok(()),
        Ok(Ok(Err(why))) => Err(format!("the far end of the link failed: {why}").into()),
        Ok(Err(why)) => Err(format!("the far end of the link failed: {why}").into()),
        Err(_) => Err("the far end of the link never finished".into()),
    }
}

/// One open path of a link, as its end has it.
struct Seen {
    helper: bool,
    chosen: bool,
    to: String,
    trip: Duration,
    sent: u64,
    got: u64,
}

/// Every open path of a link, as it stands now.
fn paths(link: &Connection) -> Vec<Seen> {
    link.paths()
        .iter()
        .map(|path| {
            let stats = path.stats();
            Seen { helper: path.is_relay(), chosen: path.is_selected(), to: path.remote_addr().to_string(), trip: stats.rtt, sent: stats.udp_tx.bytes, got: stats.udp_rx.bytes }
        })
        .collect()
}

/// The paths in words, for a line of the report.
fn said(paths: &[Seen]) -> String {
    if paths.is_empty() {
        return "none".into();
    }
    let one = |p: &Seen| {
        format!(
            "{} {}{} ({} a round trip, {} bytes sent, {} got)",
            if p.helper { "through the helper" } else { "straight" },
            p.to,
            if p.chosen { ", the one in use" } else { "" },
            ms(p.trip),
            p.sent,
            p.got
        )
    };
    paths.iter().map(one).collect::<Vec<_>>().join("; ")
}

/// The address of the straight path a link has chosen, if it chooses one in time.
async fn straight(link: &Connection, within: Duration) -> Option<String> {
    let mut changes = link.paths_stream();
    let chosen = timeout(within, changes.wait_any(|path| path.is_selected() && path.is_ip())).await.ok().flatten();
    chosen.map(|path| path.remote_addr().to_string())
}

/// A time in milliseconds, with a decimal place under ten.
fn ms(took: Duration) -> String {
    let ms = took.as_secs_f64() * 1000.0;
    if ms < 10.0 { format!("{ms:.1} ms") } else { format!("{ms:.0} ms") }
}

/// A plain HTTP GET, for the two doors a helper keeps to its own machine. The status and the body.
async fn get(to: SocketAddr, path: &str) -> Res<(u16, String)> {
    let mut stream = timeout(Duration::from_secs(5), TcpStream::connect(to)).await.map_err(|_| "no answer")??;
    stream.write_all(format!("GET {path} HTTP/1.1\r\nHost: {to}\r\nConnection: close\r\n\r\n").as_bytes()).await?;
    let mut answer = Vec::new();
    timeout(Duration::from_secs(5), stream.read_to_end(&mut answer)).await.map_err(|_| "the answer never ended")??;
    let answer = String::from_utf8_lossy(&answer).into_owned();
    let status = answer.split_whitespace().nth(1).and_then(|s| s.parse().ok()).ok_or("not an HTTP answer")?;
    Ok((status, answer.split_once("\r\n\r\n").map(|(_, body)| body.to_string()).unwrap_or_default()))
}

/// What a helper started here says it has counted (its metrics door).
struct Counted {
    bytes_in: u64,
    bytes_out: u64,
    signed_in: u64,
    slowed: u64,
}

/// A link helper started here, and stopped when this is dropped whatever else happens.
struct Started {
    child: Child,
    dir: PathBuf,
    helper: Helper,
    plain: SocketAddr,
    metrics: SocketAddr,
    /// The limit per device in the settings it was given: bytes a second, and bytes at once.
    limit: Option<(u64, u64)>,
}

impl Started {
    /// Starts `program` as relay/deploy's samples (in `samples`) have it started: link-helper.toml.example's
    /// settings, moved to free ports on this machine and a certificate made here, and ghost-link.service's
    /// environment. With `token`, it lets in only devices that present it.
    fn start(program: &Path, samples: &Path, token: Option<&str>) -> Res<Started> {
        if !program.is_file() {
            return Err(format!("no link helper at {}: build it first (tool/build-link.sh host)", program.display()).into());
        }
        let sample = samples.join("link-helper.toml.example");
        let sample_text = fs::read_to_string(&sample).map_err(|e| format!("{}: {e}", sample.display()))?;
        let service = samples.join("ghost-link.service");
        let service_text = fs::read_to_string(&service).map_err(|e| format!("{}: {e}", service.display()))?;
        let environment: Vec<(&str, &str)> = service_text.lines().filter_map(|l| l.strip_prefix("Environment=")).flat_map(str::split_whitespace).filter_map(|pair| pair.split_once('=')).collect();
        if !environment.iter().any(|(name, _)| *name == "RUST_LOG") {
            return Err(format!("{} sets no RUST_LOG any more: what the helper writes is checked as the service has it write", service.display()).into());
        }
        let dir = env::temp_dir().join(format!("ghost-link-check-{}-{}", std::process::id(), if token.is_some() { "token" } else { "open" }));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir)?;
        let at = |name: &str| dir.join(name).to_string_lossy().into_owned();

        // A certificate for 127.0.0.1 that lasts two days, its key written as Caddy writes one (an EC key, "EC
        // PRIVATE KEY"), since Caddy's is what ours reads on the box.
        let openssl = |args: &[&str]| -> Res<()> {
            let out = Command::new("openssl").args(args).output().map_err(|e| format!("openssl, which makes the run's certificate, did not start: {e}"))?;
            if !out.status.success() {
                return Err(format!("openssl {} failed: {}", args[0], String::from_utf8_lossy(&out.stderr).trim()).into());
            }
            Ok(())
        };
        openssl(&["ecparam", "-genkey", "-name", "prime256v1", "-noout", "-out", &at("key.pem")])?;
        openssl(&["req", "-new", "-x509", "-key", &at("key.pem"), "-out", &at("cert.pem"), "-days", "2", "-subj", "/CN=link-check", "-addext", "subjectAltName=IP:127.0.0.1"])?;
        openssl(&["x509", "-in", &at("cert.pem"), "-outform", "DER", "-out", &at("cert.der")])?;
        let root = fs::read(at("cert.der"))?;

        // Four ports nobody has: asked for, read, and let go for the helper to take.
        let tcp = || -> Res<SocketAddr> { Ok(TcpListener::bind("127.0.0.1:0")?.local_addr()?) };
        let (https, plain, metrics) = (tcp()?, tcp()?, tcp()?);
        let quic = UdpSocket::bind("127.0.0.1:0")?.local_addr()?;

        let mut moved = vec![
            ("https_bind_addr", https.to_string()),
            ("quic_bind_addr", quic.to_string()),
            ("http_bind_addr", plain.to_string()),
            ("metrics_bind_addr", metrics.to_string()),
            ("manual_cert_path", at("cert.pem")),
            ("manual_key_path", at("key.pem")),
        ];
        let mut settings = String::new();
        let mut limit = (None, None);
        for line in sample_text.lines() {
            let name = line.split('=').next().unwrap_or("").trim();
            let value = line.split_once('=').map(|(_, v)| v.trim()).unwrap_or("");
            if let Some(found) = moved.iter().position(|(n, _)| *n == name) {
                settings.push_str(&format!("{name} = {:?}\n", moved.remove(found).1));
                continue;
            }
            match (name, token) {
                ("access", Some(token)) => {
                    settings.push_str(&format!("access.shared_token = [{token:?}]\n"));
                    continue;
                }
                ("bytes_per_second", _) => limit.0 = value.parse().ok(),
                ("max_burst_bytes", _) => limit.1 = value.parse().ok(),
                _ => {}
            }
            settings.push_str(line);
            settings.push('\n');
        }
        if let Some((name, _)) = moved.first() {
            return Err(format!("{} has no {name} line any more: this check moves that line to this machine", sample.display()).into());
        }
        fs::write(dir.join("config.toml"), settings)?;

        let wrote = fs::File::create(dir.join("helper.log"))?;
        let child = Command::new(program)
            .arg("--config-path")
            .arg(dir.join("config.toml"))
            .envs(environment)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(wrote)
            .spawn()
            .map_err(|e| format!("{} did not start: {e}", program.display()))?;
        let mut started = Started {
            child,
            dir,
            helper: Helper { url: format!("https://{https}").parse()?, quic: quic.port(), root: Some(root), token: None },
            plain,
            metrics,
            limit: limit.0.zip(limit.1),
        };
        // Up when its https port takes a connection; gone if the program has ended.
        let began = Instant::now();
        while std::net::TcpStream::connect_timeout(&https, Duration::from_millis(200)).is_err() {
            if let Some(ended) = started.child.try_wait()? {
                return Err(format!("the link helper ended as it started ({ended}):\n{}", started.wrote()).into());
            }
            if began.elapsed() > Duration::from_secs(15) {
                return Err(format!("the link helper was not listening on {https} after 15 s:\n{}", started.wrote()).into());
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        Ok(started)
    }

    /// What the helper has written so far.
    fn wrote(&self) -> String {
        fs::read_to_string(self.dir.join("helper.log")).unwrap_or_default()
    }

    /// Reads the four counters off the helper's metrics door; an error where one of them is not there.
    async fn counted(&self) -> Res<Counted> {
        let (status, body) = get(self.metrics, "/metrics").await.map_err(|e| format!("the helper's metrics door at {}: {e}", self.metrics))?;
        let count = |name: &str| -> Res<u64> {
            let line = body.lines().find(|l| l.strip_prefix(name).is_some_and(|rest| rest.starts_with(' ')));
            Ok(line.and_then(|l| l.rsplit(' ').next()).and_then(|n| n.parse().ok()).ok_or(format!("the helper's metrics (HTTP {status}) have no {name}"))?)
        };
        Ok(Counted {
            bytes_in: count("relayserver_bytes_recv_total")?,
            bytes_out: count("relayserver_bytes_sent_total")?,
            signed_in: count("relayserver_accepts_total")?,
            slowed: count("relayserver_conns_rx_ratelimited_total")?,
        })
    }

    /// Stops it as systemd will be told to (KillSignal=SIGINT), by its process id, and says how it went.
    fn stop(mut self) -> Res<String> {
        let id = self.child.id().to_string();
        let began = Instant::now();
        if !Command::new("kill").args(["-INT", &id]).status()?.success() {
            return Err(format!("process {id} could not be sent SIGINT").into());
        }
        loop {
            if let Some(ended) = self.child.try_wait()? {
                return if ended.success() { Ok(format!("process {id}, {} after the signal, {ended}", ms(began.elapsed()))) } else { Err(format!("the helper (process {id}) ended badly on SIGINT: {ended}").into()) };
            }
            if began.elapsed() > Duration::from_secs(10) {
                return Err(format!("the helper (process {id}) was still running 10 s after SIGINT").into());
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }
}

impl Drop for Started {
    fn drop(&mut self) {
        // Only ever the process this started, by the handle it was started with; a no-op once it has ended.
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The whole proof, against a helper started for it. Needs build/link/host/iroh-relay (tool/build-link.sh host).
    #[tokio::test(flavor = "multi_thread")]
    async fn a_helper_started_here_links_two_devices() {
        if let Err(why) = local(None).await {
            panic!("{why}");
        }
    }

    /// Not a check, a measurement, for reading the service's MemoryMax by: what the helper's memory comes to with a
    /// hundred devices signed in and idle (this machine's allocator; the box's will differ some).
    ///   ulimit -n 4096; cargo test memory -- --ignored --nocapture
    #[tokio::test(flavor = "multi_thread")]
    #[ignore = "a measurement, and it wants more open files than a shell allows by default"]
    async fn memory_a_hundred_devices_take() {
        const DEVICES: usize = 100;
        let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        let started = Started::start(&root.join("build/link/host/iroh-relay"), &root.join("relay/deploy"), None).unwrap();
        let memory = || -> u64 {
            let out = Command::new("ps").args(["-o", "rss=", "-p", &started.child.id().to_string()]).output().unwrap();
            String::from_utf8_lossy(&out.stdout).trim().parse().unwrap()
        };
        let before = memory();
        let made = Instant::now();
        let mut devices = Vec::new();
        for _ in 0..DEVICES {
            devices.push(device(&started.helper, true).await.unwrap());
        }
        for device in &devices {
            signed_in(device, made, "a device").await.unwrap();
        }
        sleep(Duration::from_secs(5)).await;
        let with = memory();
        let counted = started.counted().await.unwrap();
        println!("the helper alone: {before} KiB. With {} devices signed in and idle: {with} KiB, {} KiB a device", counted.signed_in, (with - before) / DEVICES as u64);
        for device in devices {
            device.close().await;
        }
        sleep(Duration::from_secs(2)).await;
        println!("after they left: {} KiB", memory());
        started.stop().unwrap();
    }
}
