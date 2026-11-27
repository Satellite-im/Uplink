import { test, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { createServer, request } from 'node:http';
import { Codes, CODE_TTL_MS } from '../src/codes.js';
import { TokenStore } from '../src/store.js';
import { createHandler, MAX_BODY } from '../src/http.js';
import { answer } from '../src/commands.js';
import { STAGE, VOICE, guild, member, voiceState } from './fakes.js';

// The HTTP routes (src/http.js) on a real server on a free loopback port, with the clock by hand and the bot's
// servers stood in for by `world`: claim and its limits, state, invite, CORS, and the /ghost commands' answers.

const G = '100000000000000001';
const APP = '200000000000000002';
let clock, codes, store, world, server, base, logs;

const fakeGuild = () => guild({
  id: G, name: 'Ghosts', icon: 'hash1',
  channels: [{ id: 'v1', name: 'Lounge', type: VOICE, rawPosition: 0 }, { id: 's1', name: 'Talks', type: STAGE, rawPosition: 1 }],
  voiceStates: [voiceState('u1', 'v1', { selfDeaf: true })],
  members: [member('u1', { nickname: 'Casper' })],
});

beforeEach(() => {
  clock = 1_700_000_000_000;
  codes = new Codes({ now: () => clock });
  store = new TokenStore(null, { now: () => clock });
  world = { ready: true, guilds: new Map([[G, fakeGuild()]]) };
  logs = [];
  server.handler = createHandler({
    codes, store, appId: APP, now: () => clock, log: (m) => logs.push(m),
    guilds: { async lookup(id) { if (!world.ready) return { status: 'starting' }; const g = world.guilds.get(id); return g ? { status: 'ok', guild: g } : { status: 'gone' }; } },
  });
});

before(async () => {
  server = createServer((req, res) => server.handler(req, res));
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${server.address().port}`;
});
after(() => server.close());

const post = (path, body, headers = {}) => fetch(base + path, { method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: typeof body === 'string' ? body : JSON.stringify(body) });
const json = async (res) => [res.status, await res.json()];

test('claim: a code makes a token and gives the server; it works once', async () => {
  const code = answer({ sub: 'link', guildId: G, canManage: true }, { codes, store }).match(/code is ([A-Z0-9]{6})\./)[1];
  const [status, body] = await json(await post('/discord/claim', { code }));
  assert.equal(status, 200);
  assert.match(body.token, /^[0-9a-f]{32}$/);
  assert.deepEqual(body.guild, { id: G, name: 'Ghosts', icon: `https://cdn.discordapp.com/icons/${G}/hash1.png` });
  assert.deepEqual(await json(await post('/discord/claim', { code })), [404, { error: 'unknown code' }]);
  assert.ok(logs.every((l) => !l.includes(code) && !l.includes(body.token)));
});

test('claim: the /claim form without the prefix works too, and each claim is a new token', async () => {
  const a = await json(await post('/claim', { code: codes.issue(G) }));
  const b = await json(await post('/discord/claim', { code: codes.issue(G) }));
  assert.equal(a[0], 200);
  assert.notEqual(a[1].token, b[1].token);
  assert.equal(store.countGuild(G), 2);
});

test('claim: an expired code is 404 after ten minutes', async () => {
  const code = codes.issue(G);
  clock += CODE_TTL_MS;
  assert.deepEqual(await json(await post('/discord/claim', { code })), [404, { error: 'unknown code' }]);
});

test('claim: a wrong code is 404; bad JSON 400', async () => {
  codes.issue(G);
  assert.deepEqual(await json(await post('/discord/claim', { code: 'ZZZZZZ' })), [404, { error: 'unknown code' }]);
  assert.equal((await post('/discord/claim', '{nope')).status, 400);
});

test('claim: ten tries a minute per address, then 429; another address is not held back', async () => {
  const ip = { 'x-forwarded-for': '203.0.113.7' };
  for (let i = 0; i < 10; i++) assert.equal((await post('/discord/claim', { code: 'ZZZZZZ' }, ip)).status, 404);
  const held = await post('/discord/claim', { code: codes.issue(G) }, ip);
  assert.equal(held.status, 429);
  assert.ok(Number(held.headers.get('retry-after')) >= 1);
  assert.equal((await post('/discord/claim', { code: 'ZZZZZZ' }, { 'x-forwarded-for': '203.0.113.8' })).status, 404);
  clock += 60_000;
  assert.equal((await post('/discord/claim', { code: codes.issue(G) }, ip)).status, 200);
});

test('claim: a body over 4 KB is refused with 413', async () => {
  const res = await post('/discord/claim', JSON.stringify({ code: 'A'.repeat(MAX_BODY) }));
  assert.equal(res.status, 413);
});

test('claim: a body over 4 KB sent without a length (chunked) is refused too', async () => {
  const { port } = server.address();
  const status = await new Promise((resolve, reject) => {
    const req = request({ host: '127.0.0.1', port, path: '/discord/claim', method: 'POST', headers: { 'transfer-encoding': 'chunked' } }, (res) => { res.resume(); resolve(res.statusCode); });
    req.on('error', reject);
    for (let i = 0; i < 10; i++) req.write('x'.repeat(1024));
    req.end();
  });
  assert.equal(status, 413);
});

test('state: the shape the app reads', async () => {
  const { token } = (await json(await post('/discord/claim', { code: codes.issue(G) })))[1];
  const [status, body] = await json(await fetch(`${base}/discord/state?token=${token}`));
  assert.equal(status, 200);
  assert.deepEqual(body, {
    guild: { id: G, name: 'Ghosts', icon: `https://cdn.discordapp.com/icons/${G}/hash1.png` },
    channels: [
      { id: 'v1', name: 'Lounge', kind: 'voice', position: 0, members: [{ id: 'u1', name: 'Casper', avatar: null, muted: false, deafened: true, video: false, streaming: false, bot: false }] },
      { id: 's1', name: 'Talks', kind: 'stage', position: 1, members: [] },
    ],
    at: clock,
  });
  assert.equal((await fetch(`${base}/state?token=${token}`)).status, 200);
});

test('state: unknown or missing token 401; after /ghost unlink 401; bot removed 410', async () => {
  assert.deepEqual(await json(await fetch(`${base}/discord/state?token=${'a'.repeat(32)}`)), [401, { error: 'not linked' }]);
  assert.deepEqual(await json(await fetch(`${base}/discord/state`)), [401, { error: 'not linked' }]);
  const { token } = (await json(await post('/discord/claim', { code: codes.issue(G) })))[1];
  world.guilds.delete(G);
  assert.deepEqual(await json(await fetch(`${base}/discord/state?token=${token}`)), [410, { error: 'gone' }]);
  world.guilds.set(G, fakeGuild());
  assert.equal((await fetch(`${base}/discord/state?token=${token}`)).status, 200);
  assert.match(answer({ sub: 'unlink', guildId: G, canManage: true }, { codes, store }), /1 Uplink link was revoked/);
  assert.deepEqual(await json(await fetch(`${base}/discord/state?token=${token}`)), [401, { error: 'not linked' }]);
});

test('state: 503 while the bot is still connecting', async () => {
  const { token } = (await json(await post('/discord/claim', { code: codes.issue(G) })))[1];
  world.ready = false;
  assert.equal((await fetch(`${base}/discord/state?token=${token}`)).status, 503);
});

test('invite: the bot\'s invite link, with the permissions the bridge needs', async () => {
  // View Channel 1024 + Send Messages 2048 + Read Message History 65536 + Connect 1048576 + Speak 2097152
  // + Use Voice Activity 33554432 + Change Nickname 67108864 + Manage Webhooks 536870912
  assert.equal(1024 + 2048 + 65536 + 1048576 + 2097152 + 33554432 + 67108864 + 536870912, 640748544);
  assert.deepEqual(await json(await fetch(`${base}/discord/invite`)), [200, { url: `https://discord.com/oauth2/authorize?client_id=${APP}&scope=bot%20applications.commands&permissions=640748544` }]);
  assert.equal((await fetch(`${base}/invite`)).status, 200);
});

test('CORS: any origin, GET and POST; a preflight is answered', async () => {
  const pre = await fetch(`${base}/discord/claim`, { method: 'OPTIONS', headers: { origin: 'https://example.com', 'access-control-request-method': 'POST', 'access-control-request-headers': 'content-type' } });
  assert.equal(pre.status, 204);
  assert.equal(pre.headers.get('access-control-allow-origin'), '*');
  assert.match(pre.headers.get('access-control-allow-methods'), /GET/);
  assert.match(pre.headers.get('access-control-allow-methods'), /POST/);
  assert.match(pre.headers.get('access-control-allow-headers'), /Content-Type/i);
  const res = await fetch(`${base}/discord/state?token=x`, { headers: { origin: 'https://example.com' } });
  assert.equal(res.headers.get('access-control-allow-origin'), '*');
  assert.match(res.headers.get('content-type'), /^application\/json/);
});

test('other paths and methods', async () => {
  assert.equal((await fetch(`${base}/discord/nope`)).status, 404);
  assert.equal((await fetch(`${base}/discord/claim`)).status, 405);
  assert.deepEqual(await json(await fetch(`${base}/discord/`)), [200, { ok: true, service: 'ghost-discord' }]);
});

test('commands: link and unlink need Manage Server; status counts links', () => {
  assert.match(answer({ sub: 'link', guildId: G, canManage: false }, { codes, store }), /Manage Server/);
  assert.match(answer({ sub: 'unlink', guildId: G, canManage: false }, { codes, store }), /Manage Server/);
  const text = answer({ sub: 'link', guildId: G, canManage: true }, { codes, store });
  assert.match(text, /^Your code is [23456789ABCDEFGHJKMNPQRSTUVWXYZ]{6}\. In Uplink tap New › Add a Discord server and enter it\. It works once, for 10 minutes\.$/);
  assert.match(answer({ sub: 'status', guildId: G, canManage: false }, { codes, store }), /no Uplink links/);
  store.add(G); store.add(G);
  assert.equal(answer({ sub: 'status', guildId: G, canManage: false }, { codes, store }), 'This server has 2 Uplink links.');
  // unlink cancels waiting codes too
  const code = codes.issue(G);
  answer({ sub: 'unlink', guildId: G, canManage: true }, { codes, store });
  assert.equal(codes.take(code), null);
});
