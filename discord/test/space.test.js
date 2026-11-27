// The bridge as a member of an Uplink space, through the fake hub, with the browser join page's own Hangout and Chat
// (site/join/voice.js) on the other side: who it says it is, the Discord people, signalling, and the chat both ways.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as page from '../../site/join/voice.js';
import { Hub, makeIdentity } from '../src/bridge/hub.js';
import { openJson, sealJson, spaceKeys } from '../src/bridge/protocol.js';
import { GhostSpace } from '../src/bridge/space.js';
import { FakeHub, until } from './fakehub.js';

const SEED = '5e'.repeat(32);

/** WebRTC stand-ins: each answers an offer with "answer:<offer>" and records what it was given. */
function fakePeers() {
  const made = new Map();
  const factory = (id, hooks) => {
    const p = { id, hooks, offers: [], answers: [], candidates: [], sent: [], closed: false,
      async makeOffer() { return `offer-from-bridge-to-${id}`; },
      async takeOffer(sdp) { p.offers.push(sdp); return `answer:${sdp}`; },
      async takeAnswer(sdp) { p.answers.push(sdp); },
      async addCandidate(c) { p.candidates.push(c); },
      send(opus) { p.sent.push(opus); },
      async close() { p.closed = true; },
    };
    made.set(id, p);
    return p;
  };
  return { factory, made };
}

/** A GhostSpace opened on a signed-in fake hub, with everything it tells its owner recorded in `events`. */
async function setup() {
  const fake = new FakeHub();
  const me = makeIdentity();
  const hub = new Hub({ url: 'ws://fake', me, connect: () => fake.connect() });
  hub.start();
  await until(() => hub.up, 2000, 'hub');
  const peers = fakePeers();
  const events = { members: [], chat: [], up: [], down: [], audio: [] };
  const space = new GhostSpace({
    hub, seed: SEED, peers: peers.factory,
    on: { members: (l) => events.members.push(l), chat: (m) => events.chat.push(m), peerUp: (id) => events.up.push(id), peerDown: (id) => events.down.push(id), audio: (id, o) => events.audio.push([id, o]) },
  });
  await space.open();
  return { fake, hub, me, space, peers, events };
}

/** A raw member of the call's room that can say anything and records what it hears, opened with the space key. */
async function rawMember(fake, id, room = 'voice') {
  const k = spaceKeys(SEED);
  const b = fake.browser(id);
  const heard = [];
  b.bin.add((d) => { const m = openJson(k.key, Buffer.from(d.subarray(33))); if (m) heard.push({ from: Buffer.from(d.subarray(17, 33)).toString('hex'), ...m }); });
  const events = [];
  b.json.add((m) => events.push(m));
  const name = room === 'voice' ? k.voiceRoom : k.chatRoom;
  b.say({ join: name, token: room === 'voice' ? k.voiceToken : k.chatToken });
  await until(() => events.some((e) => e.room === name && e.ok), 2000, 'raw join');
  const say = (m) => b.ws.send(Buffer.concat([Buffer.from([2]), Buffer.from(name, 'hex'), sealJson(k.key, m)]));
  return { b, heard, events, say };
}

test('a newcomer offers; the bridge answers, says it is "Discord" and who is on the Discord side', async () => {
  const { fake, me, space, peers, events, hub } = await setup();
  space.setPeople([{ id: '1', name: 'Amy', avatar: null, speaking: true, muted: false, deafened: false, bot: false }]);
  const app = await rawMember(fake, 'a1'.repeat(16));
  app.say({ t: 'me', n: 'Matt', m: false, v: false });
  app.say({ t: 'ice', to: me.id, c: { candidate: 'candidate:1 1 udp 1 1.2.3.4 5 typ host', sdpMid: '0', sdpMLineIndex: 0 } });
  app.say({ t: 'offer', to: me.id, sdp: 'v=0 offer' });
  await until(() => app.heard.some((m) => m.t === 'answer'), 2000, 'answer');
  const answer = app.heard.find((m) => m.t === 'answer');
  assert.deepEqual([answer.to, answer.sdp], ['a1'.repeat(16), 'answer:v=0 offer']);
  assert.deepEqual(app.heard.find((m) => m.t === 'me'), { from: me.id, t: 'me', n: 'Discord', m: false, v: false });
  const dc = app.heard.find((m) => m.t === 'dc');
  assert.deepEqual(dc.people, [{ id: '1', name: 'Amy', avatar: null, speaking: true, muted: false, deafened: false, bot: false }]);
  assert.deepEqual(Object.keys(dc.people[0]), ['id', 'name', 'avatar', 'speaking', 'muted', 'deafened', 'bot']);
  await until(() => space.list().some((m) => m.name === 'Matt'), 2000, 'name');
  assert.deepEqual(space.list(), [{ id: 'a1'.repeat(16), name: 'Matt' }]);
  // The candidate that came before the offer was handed to the same connection.
  assert.equal(peers.made.get('a1'.repeat(16)).candidates.length, 1);
  // Its connection coming up makes it a recipient of sound; sound goes only to a connected member.
  const p = peers.made.get('a1'.repeat(16));
  space.sendAudio('a1'.repeat(16), Buffer.from([1]));
  assert.equal(p.sent.length, 0);
  p.hooks.onState('connected');
  assert.deepEqual(events.up, ['a1'.repeat(16)]);
  space.sendAudio('a1'.repeat(16), Buffer.from([1]));
  assert.equal(p.sent.length, 1);
  // Gone from the room: connection closed, a member less.
  app.b.say({ leave: spaceKeys(SEED).voiceRoom });
  await until(() => space.members.size === 0, 2000, 'went');
  assert.equal(p.closed, true);
  assert.deepEqual(events.down, ['a1'.repeat(16)]);
  await space.close();
  hub.stop();
});

test('voice.js\'s own Hangout reads the bridge as a member named Discord; messages for others are not answered', async () => {
  const { fake, space, hub, me } = await setup();
  const browser = fake.browser('b2'.repeat(16));
  const hangout = new page.Hangout(browser, SEED, () => {});
  await hangout.prepare();
  hangout.offer = async () => {}; // its WebRTC half needs a browser; the signalling is tested with raw members
  // Joining without a microphone: what Hangout.join sends, minus getUserMedia.
  browser.say({ join: hangout.room, token: hangout.token });
  await until(() => hangout.members.get(me.id)?.name === 'Discord', 2000, 'Hangout sees the bridge');
  assert.equal(hangout.members.get(me.id).muted, false);
  // An offer addressed to someone else is ignored.
  const other = await rawMember(fake, 'c3'.repeat(16));
  other.say({ t: 'offer', to: 'ff'.repeat(16), sdp: 'not for the bridge' });
  await new Promise((r) => setTimeout(r, 30));
  assert.equal([...space.members.values()].filter((m) => m.described).length, 0);
  await space.close();
  hub.stop();
});

test('already there when the bridge comes in: the bridge offers to each, and takes their answers', async () => {
  const fake = new FakeHub();
  const app = await rawMember(fake, 'd4'.repeat(16));
  const me = makeIdentity();
  const hub = new Hub({ url: 'ws://fake', me, connect: () => fake.connect() });
  hub.start();
  const peers = fakePeers();
  const space = new GhostSpace({ hub, seed: SEED, peers: peers.factory });
  await space.open();
  await until(() => app.heard.some((m) => m.t === 'offer'), 2000, 'offer');
  assert.equal(app.heard.find((m) => m.t === 'offer').to, 'd4'.repeat(16));
  app.say({ t: 'answer', to: me.id, sdp: 'their answer' });
  await until(() => peers.made.get('d4'.repeat(16)).answers.length === 1, 2000, 'answer taken');
  await space.close();
  hub.stop();
});

test('chat: voice.js\'s Chat and the bridge talk both ways; the bridge\'s own messages never come back to it', async () => {
  const { fake, space, events, hub, me } = await setup();
  const browser = fake.browser('e5'.repeat(16));
  const changes = [];
  const chat = new page.Chat(browser, SEED, '', () => changes.push(1));
  await chat.prepare();
  chat.open({ name: 'Matt', guest: false });
  await until(() => chat.opened && space.present.get('e5'.repeat(16)) === 'Matt', 2000, 'chat open');
  await until(() => chat.present.get(me.id)?.name === 'Discord', 2000, 'the bridge\'s hello');
  // Uplink -> bridge
  assert.equal(chat.send('hello from Uplink'), true);
  await until(() => events.chat.length === 1, 2000, 'message to the bridge');
  assert.deepEqual({ ...events.chat[0], id: undefined }, { from: 'e5'.repeat(16), name: 'Matt', text: 'hello from Uplink', id: undefined });
  // bridge -> Uplink, as from a Discord author
  assert.equal(space.sendChat({ name: 'Amy', text: '  hi from Discord  ', at: 1234 }), true);
  await until(() => chat.messages.some((m) => m.x === 'hi from Discord'), 2000, 'message to Uplink');
  const m = chat.messages.find((x) => x.x === 'hi from Discord');
  assert.deepEqual([m.n, m.f, m.at], ['Amy', me.id, 1234]);
  assert.equal(events.chat.length, 1, 'the bridge\'s own message is not handed back to it');
  assert.equal(space.sendChat({ name: 'Amy', text: '   ' }), false);
  // History asked for by a newcomer is answered by the lowest id present; old messages are never re-posted.
  const late = fake.browser('00'.repeat(16));
  const lateChat = new page.Chat(late, SEED, '', () => {});
  await lateChat.prepare();
  lateChat.open({ name: 'Late', guest: true });
  await until(() => lateChat.messages.length >= 2, 2000, 'history');
  assert.equal(events.chat.length, 1);
  await space.close();
  hub.stop();
});
