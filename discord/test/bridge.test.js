// The bridges as a whole, with the Discord half faked, the hub faked, WebRTC faked and the clock by hand: joining
// both sides (once), the leave rule, the Discord people said to the space, the nickname, chat both ways, and what
// happens when Discord drops the bot.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Bridges, LEAVE_AFTER_MS } from '../src/bridge/bridge.js';
import { Hub, makeIdentity } from '../src/bridge/hub.js';
import { openJson, sealJson, spaceKeys } from '../src/bridge/protocol.js';
import { BridgeStore } from '../src/bridge/store.js';
import { FakeHub, manualTimers, until } from './fakehub.js';

const G = '100000000000000001';
const C = '400000000000000004';
const C2 = '400000000000000005';

/** A codec that does no work: every packet decodes to nothing and every frame encodes to one byte. */
const rawCodec = { silence: Buffer.from([0]), decoder: () => ({ decode: () => new Int16Array(0) }), encoder: () => ({ encode: () => Buffer.from([1]) }) };

/** The Discord half, recording what the bridge asks of it; `fail` makes joining voice fail, `inChannel` is who
 * people() answers with. */
function fakeDiscord() {
  const d = {
    joins: [], links: [], nicknames: [], posts: [], inChannel: [], fail: null,
    async joinVoice(guildId, channelId, on) {
      d.joins.push([guildId, channelId]);
      if (d.fail) throw new Error(d.fail);
      const link = { on, played: [], quiets: 0, destroyed: false, play(o) { link.played.push(o); }, quiet() { link.quiets++; }, destroy() { link.destroyed = true; } };
      d.links.push(link);
      return link;
    },
    peopleCalls: 0,
    people(guildId, channelId, speaking) {
      d.peopleCalls++;
      return d.inChannel.map((p) => ({ ...p, speaking: speaking.has(p.id) }));
    },
    async setNickname(guildId, text) { d.nicknames.push(text); },
    async postText(guildId, channelId, m) { d.posts.push(m); },
  };
  return d;
}

/** WebRTC connections that do nothing. */
const fakePeers = () => (id, hooks) => ({ async makeOffer() { return 'o'; }, async takeOffer() { return 'a'; }, async takeAnswer() {}, async addCandidate() {}, send() {}, async close() {}, hooks });

/** Bridges on a signed-in fake hub, with timers moved by hand and tickers that only record being started. */
async function setup() {
  const fake = new FakeHub();
  const me = makeIdentity();
  const hub = new Hub({ url: 'ws://fake', me, connect: () => fake.connect() });
  hub.start();
  await until(() => hub.up, 2000, 'hub');
  const timers = manualTimers();
  const discord = fakeDiscord();
  const store = new BridgeStore(null);
  const tickers = [];
  const logs = [];
  const bridges = new Bridges({
    store, hub, peers: fakePeers(), codec: rawCodec, discord, log: (m) => logs.push(m), now: timers.now,
    setTimer: timers.setTimer, clearTimer: timers.clearTimer, setInterval: timers.setInterval, clearInterval: timers.clearInterval,
    ticker: (f) => { const t = { f, started: false, start() { t.started = true; }, stop() { t.started = false; } }; tickers.push(t); return t; },
    nicknameDelayMs: 100,
  });
  return { fake, me, hub, timers, discord, store, bridges, tickers, logs };
}

/** An Uplink app in the space: joins the call's room (and the chat room) and records what it hears. */
async function app(fake, id, seed, { name = 'Matt' } = {}) {
  const k = spaceKeys(seed);
  const b = fake.browser(id);
  const heard = [];
  b.bin.add((d) => { const m = openJson(k.key, Buffer.from(d.subarray(33))); if (m) heard.push(m); });
  b.say({ join: k.voiceRoom, token: k.voiceToken });
  b.say({ join: k.chatRoom, token: k.chatToken });
  const say = (room, m) => b.ws.send(Buffer.concat([Buffer.from([2]), Buffer.from(room, 'hex'), sealJson(k.key, m)]));
  await until(() => fake.members(k.voiceRoom).includes(id), 2000, 'app in');
  say(k.voiceRoom, { t: 'me', n: name, m: false, v: false });
  return { b, heard, k, say, leave: () => b.say({ leave: k.voiceRoom }) };
}

test('ensure: joins Discord voice and the space once, answers the seed and the bridge\'s hub id; /state sees it', async () => {
  const { bridges, discord, me, fake, store, hub } = await setup();
  const [a, b] = await Promise.all([bridges.ensure(G, C), bridges.ensure(G, C)]);
  assert.deepEqual(a, { seed: store.seedFor(G, C), bridge: me.id });
  assert.deepEqual(b, a);
  assert.equal(discord.joins.length, 1);
  const k = spaceKeys(a.seed);
  assert.ok(fake.members(k.voiceRoom).includes(me.id));
  assert.ok(fake.members(k.chatRoom).includes(me.id));
  await bridges.ensure(G, C);
  assert.equal(discord.joins.length, 1, 'idempotent');
  assert.deepEqual([...bridges.bridged(G)], [C]);
  assert.deepEqual([...bridges.bridged('100000000000000009')], []);
  await bridges.stopAll('test');
  hub.stop();
});

test('leave: 30 s with nobody from Uplink and the bridge leaves both sides; someone there keeps it', async () => {
  const { bridges, discord, timers, fake, me, hub } = await setup();
  const { seed } = await bridges.ensure(G, C);
  const k = spaceKeys(seed);
  timers.advance(LEAVE_AFTER_MS - 1000);
  const matt = await app(fake, 'a1'.repeat(16), seed);
  await until(() => bridges.find(G, C).space.members.size === 1, 2000, 'member');
  timers.advance(5 * LEAVE_AFTER_MS);
  assert.ok(bridges.find(G, C), 'stays while someone is there');
  matt.leave();
  await until(() => bridges.find(G, C).space.members.size === 0, 2000, 'went');
  timers.advance(LEAVE_AFTER_MS - 1);
  assert.ok(bridges.find(G, C));
  timers.advance(1);
  await until(() => !bridges.find(G, C), 2000, 'left');
  assert.equal(discord.links[0].destroyed, true);
  await until(() => !fake.members(k.voiceRoom).includes(me.id) && !fake.members(k.chatRoom).includes(me.id), 2000, 'out of the rooms');
  assert.deepEqual([...bridges.bridged(G)], []);
  hub.stop();
});

test('a join request starts the leave clock over', async () => {
  const { bridges, timers, hub } = await setup();
  await bridges.ensure(G, C);
  timers.advance(LEAVE_AFTER_MS - 5000);
  await bridges.ensure(G, C);
  timers.advance(LEAVE_AFTER_MS - 5000);
  assert.ok(bridges.find(G, C));
  timers.advance(5000);
  await until(() => !bridges.find(G, C), 2000, 'left');
  hub.stop();
});

test('dc: the Discord people said to the space at once, on speaking changes, and every 5 s', async () => {
  const { bridges, discord, timers, fake, hub } = await setup();
  discord.inChannel = [{ id: 'u1', name: 'Amy', avatar: null, muted: false, deafened: false, bot: false }];
  const { seed } = await bridges.ensure(G, C);
  const matt = await app(fake, 'a1'.repeat(16), seed);
  await until(() => matt.heard.some((m) => m.t === 'dc'), 2000, 'dc');
  assert.deepEqual(matt.heard.find((m) => m.t === 'dc').people, [{ id: 'u1', name: 'Amy', avatar: null, muted: false, deafened: false, bot: false, speaking: false }]);
  discord.links[0].on.speaking('u1', true);
  await until(() => matt.heard.some((m) => m.t === 'dc' && m.people[0]?.speaking), 2000, 'speaking');
  const before = matt.heard.filter((m) => m.t === 'dc').length;
  discord.links[0].on.speaking('u1', true); // no change: nothing said
  timers.advance(5000);
  await until(() => matt.heard.filter((m) => m.t === 'dc').length === before + 1, 2000, 'every 5 s');
  // Someone joining the Discord channel is said at once.
  discord.inChannel.push({ id: 'u2', name: 'Bo', avatar: null, muted: true, deafened: false, bot: false });
  bridges.voiceChanged(G, C);
  await until(() => matt.heard.at(-1).t === 'dc' && matt.heard.at(-1).people.length === 2, 2000, 'came');
  await bridges.stopAll('test');
  hub.stop();
});

test('nickname: "Uplink · Matt" for one person from Uplink, "Uplink · 2 people" for two, reset when the bridge leaves', async () => {
  const { bridges, discord, timers, fake, hub } = await setup();
  const { seed } = await bridges.ensure(G, C);
  await app(fake, 'a1'.repeat(16), seed, { name: 'Matt' });
  await until(() => bridges.find(G, C).names.includes('Matt'), 2000, 'name');
  timers.advance(100);
  assert.deepEqual(discord.nicknames, ['Uplink · Matt']);
  const casper = await app(fake, 'b2'.repeat(16), seed, { name: 'Casper' });
  await until(() => bridges.find(G, C).names.length === 2 && bridges.find(G, C).names.every(Boolean), 2000, 'two');
  timers.advance(100);
  assert.deepEqual(discord.nicknames, ['Uplink · Matt', 'Uplink · 2 people']);
  timers.advance(100);
  assert.equal(discord.nicknames.length, 2, 'unchanged: not set again');
  casper.leave();
  await bridges.stopAll('test');
  timers.advance(100);
  assert.equal(discord.nicknames.at(-1), null);
  hub.stop();
});

test('chat: Discord -> the space as from the author; the space -> Discord with the sender\'s name; no echo', async () => {
  const { bridges, discord, fake, hub } = await setup();
  const { seed } = await bridges.ensure(G, C);
  const matt = await app(fake, 'a1'.repeat(16), seed);
  await until(() => bridges.find(G, C).space.inChat, 2000, 'chat');
  assert.equal(bridges.discordText(G, C, { name: 'Amy', text: 'hello Uplink' }), true);
  await until(() => matt.heard.some((m) => m.t === 'msg'), 2000, 'msg');
  const m = matt.heard.find((x) => x.t === 'msg');
  assert.deepEqual([m.n, m.x], ['Amy', 'hello Uplink']);
  assert.match(m.id, /^[0-9a-f]{16}$/);
  assert.equal(discord.posts.length, 0, 'what Discord said is not posted back to Discord');
  matt.say(matt.k.chatRoom, { t: 'msg', id: '0123456789abcdef', x: 'hello Discord', at: 5, n: 'Matt' });
  await until(() => discord.posts.length === 1, 2000, 'post');
  assert.deepEqual(discord.posts[0], { name: 'Matt', text: 'hello Discord' });
  // The same message again (a resend, or history) is not posted twice.
  matt.say(matt.k.chatRoom, { t: 'msg', id: '0123456789abcdef', x: 'hello Discord', at: 5, n: 'Matt' });
  matt.say(matt.k.chatRoom, { t: 'hist', to: bridges.find(G, C).space.me, m: [{ id: 'aaaaaaaaaaaaaaaa', x: 'old', at: 1, n: 'X', f: 'ff'.repeat(16) }] });
  await new Promise((r) => setTimeout(r, 30));
  assert.equal(discord.posts.length, 1);
  assert.equal(bridges.discordText(G, C2, { name: 'Amy', text: 'not bridged' }), false);
  await bridges.stopAll('test');
  hub.stop();
});

test('sound: the engine runs on the ticker; Discord is told we stopped speaking after the silence tail', async () => {
  const { bridges, discord, tickers, hub } = await setup();
  await bridges.ensure(G, C);
  const b = bridges.find(G, C);
  assert.equal(tickers[0].started, true);
  let next = { discord: Buffer.from([7]), ghost: new Map() };
  b.engine.tick = () => next;
  tickers[0].f();
  assert.deepEqual(discord.links[0].played, [Buffer.from([7])]);
  next = { discord: null, ghost: new Map() };
  tickers[0].f();
  tickers[0].f();
  assert.equal(discord.links[0].quiets, 1);
  await bridges.stopAll('test');
  assert.equal(tickers[0].started, false);
  hub.stop();
});

test('Discord drops the bot (after its one rejoin): the bridge leaves the space too', async () => {
  const { bridges, discord, fake, me, hub, logs } = await setup();
  const { seed } = await bridges.ensure(G, C);
  discord.links[0].on.lost();
  await until(() => !bridges.find(G, C), 2000, 'stopped');
  await until(() => !fake.members(spaceKeys(seed).voiceRoom).includes(me.id), 2000, 'out of the space');
  assert.ok(logs.some((l) => l.includes('disconnected from Discord voice')));
  hub.stop();
});

test('failures: Discord voice failing is a "voice" error and leaves nothing behind; another busy channel is "busy"', async () => {
  const { bridges, discord, fake, me, hub, store } = await setup();
  discord.fail = 'nope';
  await assert.rejects(bridges.ensure(G, C), (e) => e.code === 'voice');
  assert.equal(bridges.find(G, C), null);
  await until(() => !fake.members(spaceKeys(store.seedFor(G, C)).voiceRoom).includes(me.id), 2000, 'left the space');
  discord.fail = null;
  const { seed } = await bridges.ensure(G, C);
  await app(fake, 'a1'.repeat(16), seed);
  await until(() => bridges.find(G, C).space.members.size === 1, 2000, 'member');
  await assert.rejects(bridges.ensure(G, C2), (e) => e.code === 'busy');
  // With nobody from Uplink in it, the other channel gives way.
  bridges.find(G, C).space.members.clear();
  await bridges.ensure(G, C2);
  assert.equal(bridges.find(G, C), null);
  assert.ok(bridges.find(G, C2));
  await bridges.stopAll('test');
  hub.stop();
});

test('the hub not answering is a "hub" error', async () => {
  const fake = new FakeHub();
  const hub = new Hub({ url: 'ws://fake', me: makeIdentity(), connect: () => { throw new Error('down'); }, retryMs: 60_000 });
  hub.start();
  const discord = fakeDiscord();
  const bridges = new Bridges({ store: new BridgeStore(null), hub, peers: fakePeers(), codec: rawCodec, discord, joinTimeoutMs: 50, ticker: () => ({ start() {}, stop() {} }) });
  await assert.rejects(bridges.ensure(G, C), (e) => e.code === 'hub');
  assert.equal(discord.links[0].destroyed, true);
  void fake;
  hub.stop();
});

test('Discord drops the bot while the bridge is still joining: ensure fails as "voice" and nothing is left behind', async () => {
  const { bridges, discord, fake, me, hub, store } = await setup();
  const k = spaceKeys(store.seedFor(G, C));
  // The voice connection is made, the space lets the bridge in, and Discord drops the bot before start() goes on.
  const join = discord.joinVoice;
  discord.joinVoice = async (guildId, channelId, on) => {
    const link = await join(guildId, channelId, on);
    await until(() => fake.members(k.voiceRoom).includes(me.id), 2000, 'in the space');
    on.lost();
    return link;
  };
  await assert.rejects(bridges.ensure(G, C), (e) => e.code === 'voice');
  assert.equal(discord.links[0].destroyed, true);
  assert.equal(bridges.find(G, C), null);
  assert.deepEqual([...bridges.bridged(G)], []);
  await until(() => !fake.members(k.voiceRoom).includes(me.id), 2000, 'left the space');
  hub.stop();
});

test('stopAll stops a bridge that is still joining too', async () => {
  const { bridges, discord, fake, me, hub, store } = await setup();
  const k = spaceKeys(store.seedFor(G, C));
  let release;
  const held = new Promise((r) => { release = r; });
  const join = discord.joinVoice;
  discord.joinVoice = async (guildId, channelId, on) => { await held; return join(guildId, channelId, on); };
  const asked = bridges.ensure(G, C).then(() => 'in', (e) => e.code);
  await until(() => fake.members(k.voiceRoom).includes(me.id), 2000, 'in the space');
  const stopped = bridges.stopAll('test');
  release();
  await stopped;
  assert.equal(await asked, 'voice');
  assert.equal(discord.links[0].destroyed, true);
  assert.equal(bridges.find(G, C), null);
  assert.equal(bridges.starting.size, 0);
  await until(() => !fake.members(k.voiceRoom).includes(me.id), 2000, 'left the space');
  hub.stop();
});
