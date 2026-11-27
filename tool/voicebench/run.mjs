// Performance of voice and video channels with many members (Matt, 2026-11-14: "do performance testing for video
// calls and voice calls across multiple instances").
//
//   PLAYWRIGHT=<path to playwright's index.mjs> node tool/voicebench/run.mjs [--hub wss://…] [--seconds 15]
//
// Starts this branch's relay on this machine (unless --hub is given), serves bench.html, and for each scenario puts
// that many members in one channel, each a Chromium page with a made-up camera and microphone speaking the app's own
// protocol. After a few seconds to settle, it measures for --seconds: what each sends and gets, frames, sizes, loss,
// jitter, round trips, what limits the video, and the CPU the browser takes. Writes tool/voicebench/results.json and
// prints a table. Everything runs on one machine: it measures the app's load and its bit rates, not a network.
import { spawn, execFileSync } from 'node:child_process';
import { createServer } from 'node:http';
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomBytes } from 'node:crypto';

const here = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
// The value after --name, or the fallback.
const opt = (name, fallback) => { const i = args.indexOf('--' + name); return i >= 0 ? args[i + 1] : fallback; };
const seconds = Number(opt('seconds', '15'));
// How long to let the bandwidth estimate climb before measuring.
const settle = Number(opt('settle', '5'));
const only = opt('only', '');
const { chromium } = await import(process.env.PLAYWRIGHT ?? 'playwright');

// How many members, and whether with cameras. --only voice-2,video-4 runs just those.
const scenarios = [
  { name: 'voice-2', n: 2, video: false },
  { name: 'voice-4', n: 4, video: false },
  { name: 'voice-6', n: 6, video: false },
  { name: 'voice-8', n: 8, video: false },
  { name: 'video-2', n: 2, video: true },
  { name: 'video-3', n: 3, video: true },
  { name: 'video-4', n: 4, video: true },
  { name: 'video-6', n: 6, video: true },
].filter((s) => !only || only.split(',').includes(s.name));
const videoBitrate = Number(opt('video-bitrate', '12000000'));
const width = Number(opt('width', '1920')), height = Number(opt('height', '1080'));
// --fixed: as the app sent video before the bench (1080p and 12 Mb/s to everyone, resolution held), to compare.
const fixed = args.includes('--fixed');

// The relay, unless one is given.
let hub = opt('hub', '');
let relay;
if (!hub) {
  const port = 18000 + Math.floor(Math.random() * 900);
  relay = spawn('dart', ['run', 'bin/relay.dart', '--port', String(port), '--data', mkdtempSync(join(tmpdir(), 'voicebench-'))], { cwd: join(here, '../../relay'), stdio: ['ignore', 'pipe', 'inherit'] });
  await new Promise((done) => relay.stdout.on('data', (d) => { if (String(d).includes('listening')) done(); }));
  hub = `ws://127.0.0.1:${port}/hub`;
}
// bench.html, served from this machine on a free port: a page over http://127.0.0.1 may use a camera and microphone.
const page = readFileSync(join(here, 'bench.html'));
const server = createServer((req, res) => { res.setHeader('content-type', 'text/html'); res.end(page); }).listen(0, '127.0.0.1');
await new Promise((r) => server.on('listening', r));
const url = `http://127.0.0.1:${server.address().port}/`;

// The browser's processes: those of Playwright's Chromium that were not running before it started.
const playwrightPids = () => execFileSync('ps', ['-axo', 'pid=,command=']).toString().split('\n').filter((l) => l.includes('ms-playwright')).map((l) => Number(l.trim().split(/\s+/)[0]));
const before = new Set(playwrightPids());
const browser = await chromium.launch({
  args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream', '--autoplay-policy=no-user-gesture-required', '--disable-renderer-backgrounding', '--disable-background-timer-throttling'],
});
const ours = () => playwrightPids().filter((p) => !before.has(p));

// The CPU the browser and its children take, in percent of one core.
function cpu() {
  try {
    const rows = execFileSync('ps', ['-axo', 'pid=,ppid=,%cpu=,rss=']).toString().trim().split('\n').map((l) => l.trim().split(/\s+/).map(Number));
    const kids = new Map();
    for (const [pid, ppid] of rows) (kids.get(ppid) ?? kids.set(ppid, []).get(ppid)).push(pid);
    const all = new Set();
    const walk = (p) => { for (const k of kids.get(p) ?? []) { all.add(k); walk(k); } };
    for (const p of ours()) { all.add(p); walk(p); }
    let c = 0, m = 0;
    for (const [pid, , pc, rss] of rows) if (all.has(pid)) { c += pc; m += rss; }
    return { cpu: c, mb: Math.round(m / 1024) };
  } catch (_) { return { cpu: null, mb: null }; }
}

const results = [];
for (const s of scenarios) {
  // One seed a scenario: every page is given it, and so joins the same channel.
  const seed = randomBytes(32).toString('hex');
  const context = await browser.newContext({ permissions: ['microphone', 'camera'] });
  const pages = [];
  for (let i = 0; i < s.n; i++) {
    const p = await context.newPage();
    await p.goto(url);
    await p.evaluate((o) => window.bench.start(o), { hub, seed, name: 'bench ' + i, video: s.video, videoBitrate, width, height, fixed });
    pages.push(p);
  }
  const want = s.n - 1;
  // Everyone connected to everyone, then a few seconds to settle.
  const began = Date.now();
  while (Date.now() - began < 30000) {
    const up = await Promise.all(pages.map((p) => p.evaluate(() => [...window.bench.peers.values()].filter((pc) => pc.connectionState === 'connected').length)));
    if (up.every((n) => n === want)) break;
    await new Promise((r) => setTimeout(r, 250));
  }
  const connectMs = Date.now() - began;
  await new Promise((r) => setTimeout(r, settle * 1000));
  // The counters before (a) and after (b) the measured stretch, with the CPU read once a second in between: the
  // rates below are the difference over the stretch's real length.
  const a = await Promise.all(pages.map((p) => p.evaluate(() => window.bench.stats())));
  const cpus = [];
  const t0 = Date.now();
  while (Date.now() - t0 < seconds * 1000) {
    await new Promise((r) => setTimeout(r, 1000));
    cpus.push(cpu());
  }
  const b = await Promise.all(pages.map((p) => p.evaluate(() => window.bench.stats())));
  const span = (Date.now() - t0) / 1000;
  const kbps = (x, y) => (((y ?? 0) - (x ?? 0)) * 8) / span / 1000;
  const members = b.map((m, i) => {
    const before = new Map(a[i].peers.map((p) => [p.id, p]));
    const peers = m.peers.map((p) => {
      const q = before.get(p.id) ?? {};
      return {
        state: p.state, rtt: p.rtt, opus: p.opus,
        audioOut: kbps(q.audioSent, p.audioSent), audioIn: kbps(q.audioGot, p.audioGot),
        videoOut: kbps(q.videoSent, p.videoSent), videoIn: kbps(q.videoGot, p.videoGot),
        audioLost: (p.audioLost ?? 0) - (q.audioLost ?? 0), audioJitter: p.audioJitter,
        concealedPct: p.samples ? (100 * ((p.concealed ?? 0) - (q.concealed ?? 0))) / Math.max(1, (p.samples ?? 0) - (q.samples ?? 0)) : null,
        sent: p.sentW ? `${p.sentW}x${p.sentH}@${Math.round(p.sentFps ?? 0)}` : null, got: p.gotW ? `${p.gotW}x${p.gotH}@${Math.round(p.gotFps ?? 0)}` : null,
        limit: p.limit, encoder: p.encoder, encodeMs: p.encodeMs, decodeMs: p.decodeMs, freezes: (p.freezes ?? 0) - (q.freezes ?? 0),
      };
    });
    const sum = (k) => peers.reduce((t, p) => t + (p[k] ?? 0), 0);
    return { peers, up: sum('audioOut') + sum('videoOut'), down: sum('audioIn') + sum('videoIn') };
  });
  const avg = (xs) => xs.filter((x) => x != null).reduce((t, x) => t + x, 0) / Math.max(1, xs.filter((x) => x != null).length);
  const all = members.flatMap((m) => m.peers);
  const r = {
    scenario: s.name, members: s.n, video: s.video, connectMs,
    connected: all.filter((p) => p.state === 'connected').length + '/' + s.n * want,
    audioOutPerPeer: avg(all.map((p) => p.audioOut)), videoOutPerPeer: avg(all.map((p) => p.videoOut)),
    upPerMember: avg(members.map((m) => m.up)), downPerMember: avg(members.map((m) => m.down)),
    rttMs: avg(all.map((p) => (p.rtt ?? 0) * 1000)), jitterMs: avg(all.map((p) => (p.audioJitter ?? 0) * 1000)),
    audioLost: all.reduce((t, p) => t + p.audioLost, 0), concealedPct: avg(all.map((p) => p.concealedPct)),
    sent: [...new Set(all.map((p) => p.sent).filter(Boolean))].join(' '), got: [...new Set(all.map((p) => p.got).filter(Boolean))].join(' '),
    limits: [...new Set(all.map((p) => p.limit).filter(Boolean))].join(','), encoder: [...new Set(all.map((p) => p.encoder).filter(Boolean))].join(','),
    encodeMs: avg(all.map((p) => p.encodeMs)), decodeMs: avg(all.map((p) => p.decodeMs)), freezes: all.reduce((t, p) => t + p.freezes, 0),
    cpuPct: avg(cpus.map((c) => c.cpu)), cpuPerMember: avg(cpus.map((c) => c.cpu)) / s.n, memMB: Math.max(...cpus.map((c) => c.mb ?? 0)),
    opus: all.find((p) => p.opus)?.opus ?? null,
  };
  results.push(r);
  const f = (x, d = 0) => (x == null || Number.isNaN(x) ? '-' : x.toFixed(d));
  console.log(`${r.scenario.padEnd(8)} connected ${r.connected.padEnd(6)} in ${f(r.connectMs)} ms | audio ${f(r.audioOutPerPeer)} kb/s a peer | video ${f(r.videoOutPerPeer)} kb/s a peer ${r.sent || ''} | up ${f(r.upPerMember / 1000, 2)} Mb/s down ${f(r.downPerMember / 1000, 2)} Mb/s a member | loss ${r.audioLost} concealed ${f(r.concealedPct, 2)}% | cpu ${f(r.cpuPct)}% (${f(r.cpuPerMember)}% a member) ${r.memMB} MB | ${r.limits || 'no limit'} ${r.encoder}`);
  for (const p of pages) await p.evaluate(() => window.bench.leave()).catch(() => {});
  await context.close();
}
writeFileSync(join(here, 'results.json'), JSON.stringify({ at: new Date().toISOString(), hub: hub.startsWith('ws://127.0.0.1') ? 'local relay' : hub, fixed, seconds, videoBitrate, width, height, results }, null, 2));
await browser.close();
server.close();
relay?.kill();
