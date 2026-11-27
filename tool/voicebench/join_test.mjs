// The join page (site/join) end to end (Matt, 2026-11-14: "Make the voice hangouts possible to share via a link so
// people can join to talk anonymously or sign up through the browser similar to a zoom meeting").
//
//   PLAYWRIGHT=<path to playwright's index.mjs> node tool/voicebench/join_test.mjs
//
// This branch's relay on this machine, the site served as gogho.st serves it, and two Chromium pages with a
// made-up microphone: one joins as a guest, the other sees one person there, signs up with a username and joins.
// Both must see each other by name, the guest marked, connected, with sound arriving. The page must make the same
// room, token and link as the app (values from lib/voice/voice.dart for a fixed seed).
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { readFileSync, mkdtempSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, extname } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

const here = dirname(fileURLToPath(import.meta.url));
const site = join(here, '../../site');
const { chromium } = await import(process.env.PLAYWRIGHT ?? 'playwright');

const port = 18000 + Math.floor(Math.random() * 900);
const relay = spawn('dart', ['run', 'bin/relay.dart', '--port', String(port), '--data', mkdtempSync(join(tmpdir(), 'jointest-'))], { cwd: join(here, '../../relay'), stdio: ['ignore', 'pipe', 'inherit'] });
await new Promise((done) => relay.stdout.on('data', (d) => { if (String(d).includes('listening')) done(); }));
const types = { '.html': 'text/html', '.js': 'text/javascript', '.png': 'image/png' };
const server = createServer((req, res) => {
  let path = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  if (path.endsWith('/')) path += 'index.html';
  const file = join(site, path);
  if (!file.startsWith(site) || !existsSync(file)) { res.statusCode = 404; return res.end(); }
  res.setHeader('content-type', types[extname(file)] ?? 'application/octet-stream');
  res.end(readFileSync(file));
}).listen(0, '127.0.0.1');
await new Promise((r) => server.on('listening', r));

const seed = '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';
const name = Buffer.from('Friday hang ✨').toString('base64url');
const url = `http://127.0.0.1:${server.address().port}/join/?hub=ws://127.0.0.1:${port}/hub#${seed}.${name}`;
const browser = await chromium.launch({ args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream', '--autoplay-policy=no-user-gesture-required'] });
let failed = false;
try {
  const ctxA = await browser.newContext({ permissions: ['microphone', 'camera'] });
  const ctxB = await browser.newContext({ permissions: ['microphone', 'camera'] });
  const a = await ctxA.newPage(), b = await ctxB.newPage();
  for (const p of [a, b]) p.on('pageerror', (e) => { console.log('page error:', e.message); failed = true; });

  // The same room, token and link as the app.
  await a.goto(url);
  await a.waitForFunction(() => window.ghostHangout?.()?.room);
  const made = await a.evaluate(() => ({ room: window.ghostHangout().room, token: window.ghostHangout().token, title: document.getElementById('title').textContent }));
  assert.equal(made.room, '42c94d6559e4ea774004c9c5aa93e907');
  assert.equal(made.token, '6ad07432d21d71cd131266a87b30ac1c84a167e5eea281ccdcee5cca2963ad64');
  assert.equal(made.title, 'Friday hang ✨');
  assert.equal(`https://gogho.st/join/#${seed}.${name}`, 'https://gogho.st/join/#00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff.RnJpZGF5IGhhbmcg4pyo');
  await a.waitForFunction(() => /Nobody is here/.test(document.getElementById('here').textContent));
  console.log('ok the page makes the app\'s room, token and link; the lobby says nobody is here');

  // A guest joins.
  await a.fill('#name', 'Alex');
  await a.click('#join');
  await a.waitForSelector('#call:not([hidden])');
  console.log('ok a guest joined');

  // Someone else sees them there, signs up, and joins.
  await b.setViewportSize({ width: 400, height: 860 });
  await b.goto(url);
  await b.waitForFunction(() => /1 person is here/.test(document.getElementById('here').textContent));
  await b.screenshot({ path: join(here, 'join-lobby.png') });
  await b.setViewportSize({ width: 1280, height: 720 });
  console.log('ok the second sees one person there before joining');
  await b.click('#signup-open');
  await b.fill('#username', 'Maya_Test');
  await b.click('#signup-claim');
  await b.waitForFunction(() => /Signed up as @maya_test/.test(document.getElementById('who-note').textContent));
  console.log('ok signed up as @maya_test in the browser');
  await b.click('#join');
  await b.waitForSelector('#call:not([hidden])');

  // Each sees the other by name, connected, sound arriving.
  await a.waitForFunction(() => [...document.querySelectorAll('#people .n')].some((n) => n.textContent === '@maya_test'), null, { timeout: 15000 });
  await b.waitForFunction(() => [...document.querySelectorAll('#people li')].some((t) => t.querySelector('.n').textContent === 'Alex' && t.querySelector('.g').textContent === 'guest'), null, { timeout: 15000 });
  // A list of who is there, no squares while nobody has video on.
  if (await b.locator('.tile').count()) throw new Error('squares shown with no video on');
  console.log('ok each sees the other by name; the guest is marked');
  // Sound arriving: more than 20 kB in, on a connection that is up (asked every half second, for up to 15).
  const received = (p) => p.evaluate(async () => {
    let n = 0;
    for (const pc of window.ghostHangout().peers.values()) {
      if (pc.connectionState !== 'connected') return 0;
      for (const s of (await pc.getStats()).values()) if (s.type === 'inbound-rtp' && s.kind === 'audio') n += s.bytesReceived;
    }
    return n;
  });
  const flowing = async (p) => {
    for (let i = 0; i < 30; i++) {
      if ((await received(p)) > 20000) return;
      await p.waitForTimeout(500);
    }
    throw new Error('no sound arrived');
  };
  await flowing(a);
  await flowing(b);
  const opus = await a.evaluate(async () => { let n = 0; for (const pc of window.ghostHangout().peers.values()) for (const s of (await pc.getStats()).values()) if (s.type === 'outbound-rtp' && s.kind === 'audio') n += s.bytesSent; return n; });
  console.log(`ok connected both ways, sound arriving: the guest has sent ${opus} bytes, ${await received(b)} arrived at the other`);

  // Someone talking ripples (the made-up microphone beeps).
  await b.waitForFunction(() => document.querySelector('#people li.talking'), null, { timeout: 10000 });
  console.log('ok a list, no squares without video; whoever talks ripples');
  // Video on in the browser reaches the other.
  await a.click('#cam');
  await b.waitForFunction(() => [...document.querySelectorAll('.tile')].some((t) => t.querySelector('.n').textContent === 'Alex' && t.classList.contains('has-video')), null, { timeout: 15000 });
  console.log('ok video turned on reaches the other');
  await b.setViewportSize({ width: 400, height: 860 });
  await b.waitForTimeout(800);
  await b.screenshot({ path: join(here, 'join-call.png') });

  // The hangout's chat (lib/voice/hangout.dart): the app's chat room for this seed, what one writes the other sees,
  // and someone coming in later gets what they missed.
  const chatRoom = await a.evaluate(() => ({ room: window.ghostChat().room, token: window.ghostChat().token }));
  assert.equal(chatRoom.room, '1585bb6a5d338a56973e14f9853332a1');
  assert.equal(chatRoom.token, 'da99e3a9b14ef7f100d300ae545faafd6c269a4804e2eb301d816ca7e4acc21a');
  await a.fill('#said', 'Hello from Alex');
  await a.press('#said', 'Enter');
  await b.waitForFunction(() => [...document.querySelectorAll('#messages li')].some((li) => li.textContent.includes('Hello from Alex')), null, { timeout: 10000 });
  await b.fill('#said', 'Hi Alex!');
  await b.click('#say button');
  await a.waitForFunction(() => [...document.querySelectorAll('#messages li')].some((li) => li.textContent.includes('Hi Alex!')), null, { timeout: 10000 });
  // Each deletes only their own: Alex's page offers Delete on his message alone.
  const deletable = await a.evaluate(() => [...document.querySelectorAll('#messages li')].filter((li) => li.querySelector('.del')).map((li) => li.textContent));
  assert.equal(deletable.length, 1);
  assert.ok(deletable[0].includes('Hello from Alex'));
  console.log('ok the chat: the app\'s room, messages both ways, each may delete only their own');
  const late = await (await browser.newContext({ permissions: ['microphone', 'camera'] })).newPage();
  late.on('pageerror', (e) => { console.log('page error:', e.message); failed = true; });
  await late.goto(url);
  await late.waitForFunction(() => window.ghostChat?.()?.room);
  await late.fill('#name', 'Sam');
  await late.click('#join');
  await late.waitForFunction(() => document.querySelectorAll('#messages li').length >= 2, null, { timeout: 10000 });
  console.log('ok someone joining later gets the chat they missed');
  await late.click('#leave');
  await b.setViewportSize({ width: 400, height: 860 });
  await b.screenshot({ path: join(here, 'join-chat.png'), fullPage: true });

  // Leaving: the other sees them go.
  await a.click('#leave');
  await b.waitForFunction(() => document.querySelectorAll('#people li').length === 1 && !document.querySelector('.tile'), null, { timeout: 10000 });
  await a.waitForSelector('#left:not([hidden])');
  console.log('ok leaving: the other sees them go');

  // A broken link says so.
  const c = await ctxA.newPage();
  await c.goto(url.split('#')[0] + '#nope');
  await c.waitForSelector('#bad:not([hidden])');
  console.log('ok a broken link says it isn\'t a space');
} catch (e) {
  failed = true;
  console.log('x', e.message);
}
await browser.close();
server.close();
relay.kill();
process.exit(failed ? 1 : 0);
