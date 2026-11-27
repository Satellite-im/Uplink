// POST /discord/voice/join: who may (a token linked to that server), what it answers, and /state's "bridged".
import { test, before, after, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { Codes } from '../src/codes.js';
import { TokenStore } from '../src/store.js';
import { createHandler } from '../src/http.js';
import { BridgeStore } from '../src/bridge/store.js';
import { VOICE, guild } from './fakes.js';

const G = '100000000000000001';
const G2 = '100000000000000002';
const CH = '400000000000000004';
const BRIDGE_ID = 'ab'.repeat(16);
let store, world, server, base, logs, bridgeStore, ensured, channels, failWith;

beforeEach(() => {
  store = new TokenStore(null);
  bridgeStore = new BridgeStore(null);
  ensured = [];
  failWith = null;
  logs = [];
  channels = new Map([[CH, { name: 'Lounge', missing: [], full: false }]]);
  world = { ready: true, guilds: new Map([[G, guild({ id: G, channels: [{ id: CH, name: 'Lounge', type: VOICE }] })], [G2, guild({ id: G2 })]]) };
  const bridged = new Set();
  server.handler = createHandler({
    codes: new Codes(), store, appId: '200000000000000002', log: (m) => logs.push(m),
    guilds: { async lookup(id) { if (!world.ready) return { status: 'starting' }; const g = world.guilds.get(id); return g ? { status: 'ok', guild: g } : { status: 'gone' }; } },
    bridge: {
      channel: (g, id) => (g.id === G ? channels.get(id) ?? null : null),
      async ensure(guildId, channelId) {
        if (failWith) throw Object.assign(new Error('x'), { code: failWith });
        ensured.push([guildId, channelId]);
        bridged.add(channelId);
        return { seed: bridgeStore.seedFor(guildId, channelId), bridge: BRIDGE_ID };
      },
      bridged: () => bridged,
    },
  });
});

before(async () => {
  server = createServer((req, res) => server.handler(req, res));
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${server.address().port}`;
});
after(() => server.close());

const join = async (body) => {
  const res = await fetch(`${base}/discord/voice/join`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
  return [res.status, await res.json()];
};

test('a linked token gets the channel\'s seed, name, ids and the bridge\'s hub id; the same seed every time', async () => {
  const token = store.add(G);
  const [status, body] = await join({ token, channel: CH });
  assert.equal(status, 200);
  assert.deepEqual(Object.keys(body), ['seed', 'name', 'guild', 'channel', 'bridge']);
  assert.match(body.seed, /^[0-9a-f]{64}$/);
  assert.deepEqual({ ...body, seed: 'x' }, { seed: 'x', name: 'Lounge', guild: G, channel: CH, bridge: BRIDGE_ID });
  assert.deepEqual(ensured, [[G, CH]]);
  assert.equal((await join({ token: store.add(G), channel: CH }))[1].seed, body.seed, 'another linked app, the same space');
  // Logs say what happened, never the seed or the token.
  assert.ok(logs.some((l) => /bridged/.test(l)));
  assert.ok(logs.every((l) => !l.includes(body.seed) && !l.includes(token)));
  // And /state marks the channel.
  const state = await (await fetch(`${base}/discord/state?token=${token}`)).json();
  assert.equal(state.channels[0].bridged, true);
});

test('401 not linked; 401 for a token linked to another server; 404 unknown channel', async () => {
  assert.deepEqual(await join({ token: 'a'.repeat(32), channel: CH }), [401, { error: 'not linked' }]);
  assert.deepEqual(await join({ channel: CH }), [401, { error: 'not linked' }]);
  const other = store.add(G2);
  assert.deepEqual(await join({ token: other, channel: CH }), [404, { error: 'unknown channel' }], 'a channel of another server is not this token\'s');
  const token = store.add(G);
  assert.deepEqual(await join({ token, channel: '400000000000000009' }), [404, { error: 'unknown channel' }]);
  assert.deepEqual(await join({ token, channel: 'lounge' }), [404, { error: 'unknown channel' }]);
  assert.deepEqual(await join({ token }), [404, { error: 'unknown channel' }]);
  assert.equal(ensured.length, 0);
});

test('410 when the bot has left the server; 503 while it connects', async () => {
  const token = store.add(G);
  world.guilds.delete(G);
  assert.deepEqual(await join({ token, channel: CH }), [410, { error: 'gone' }]);
  world.ready = false;
  assert.equal((await join({ token, channel: CH }))[0], 503);
});

test('403 with the missing permissions; 409 when the channel is full', async () => {
  const token = store.add(G);
  channels.set(CH, { name: 'Lounge', missing: ['Connect', 'Speak'], full: false });
  assert.deepEqual(await join({ token, channel: CH }), [403, { error: 'no permission', missing: ['Connect', 'Speak'] }]);
  channels.set(CH, { name: 'Lounge', missing: [], full: true });
  assert.deepEqual(await join({ token, channel: CH }), [409, { error: 'full' }]);
  assert.equal(ensured.length, 0);
});

test('the bridge failing: busy 409, Discord voice 502, the relay 503', async () => {
  const token = store.add(G);
  failWith = 'busy';
  assert.deepEqual(await join({ token, channel: CH }), [409, { error: 'busy' }]);
  failWith = 'voice';
  assert.deepEqual(await join({ token, channel: CH }), [502, { error: 'voice failed' }]);
  failWith = 'hub';
  assert.deepEqual(await join({ token, channel: CH }), [503, { error: 'relay unreachable' }]);
});

test('bad JSON 400; GET 405; past 30 a minute from one address 429', async () => {
  const res = await fetch(`${base}/voice/join`, { method: 'POST', body: '{nope' });
  assert.equal(res.status, 400);
  assert.equal((await fetch(`${base}/discord/voice/join`)).status, 405);
  let last = 0;
  for (let i = 0; i < 31; i++) last = (await join({ token: 'a'.repeat(32), channel: CH }))[0];
  assert.equal(last, 429);
});

test('without the bridge (GHOST_BRIDGE=off) a join is 503 and /state has no "bridged"', async () => {
  const token = store.add(G);
  server.handler = createHandler({ codes: new Codes(), store, guilds: { async lookup(id) { return { status: 'ok', guild: world.guilds.get(id) }; } } });
  assert.deepEqual(await join({ token, channel: CH }), [503, { error: 'starting' }]);
  const state = await (await fetch(`${base}/discord/state?token=${token}`)).json();
  assert.equal('bridged' in state.channels[0], false);
});
