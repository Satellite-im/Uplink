// The bridge's Uplink protocol against the browser join page's own code (site/join/voice.js): the same rooms from a
// seed, packets each side can open, the same SDP changes, and the hub's sign-in.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import * as page from '../../site/join/voice.js';
import { Hub, makeIdentity } from '../src/bridge/hub.js';
import { derive, highestOpus, open, openJson, parseRoomFrame, roomFrame, seal, sealJson, spaceKeys, unhex } from '../src/bridge/protocol.js';
import { FakeHub, until } from './fakehub.js';

const SEED = 'ab'.repeat(32);

test('derive is HMAC-SHA256 over "ghost-net <label>" and 0x01, as WebCrypto computes it in voice.js', async () => {
  const key = await crypto.subtle.importKey('raw', unhex(SEED), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const want = new Uint8Array(await crypto.subtle.sign('HMAC', key, new Uint8Array([...new TextEncoder().encode('ghost-net voice room'), 1])));
  assert.deepEqual(new Uint8Array(derive(unhex(SEED), 'voice room')), want);
});

test('a space\'s rooms and key are what voice.js\'s Hangout and Chat derive from the same seed', async () => {
  const fake = new FakeHub();
  const b = fake.browser('11'.repeat(16));
  const hangout = new page.Hangout(b, SEED, () => {});
  await hangout.prepare();
  const chat = new page.Chat(b, SEED, '', () => {});
  await chat.prepare();
  const k = spaceKeys(SEED);
  assert.equal(k.voiceRoom, hangout.room);
  assert.equal(k.voiceToken, hangout.token);
  assert.equal(k.chatRoom, chat.room);
  assert.equal(k.chatToken, chat.token);
  assert.match(k.voiceRoom, /^[0-9a-f]{32}$/);
  assert.match(k.voiceToken, /^[0-9a-f]{64}$/);
  assert.notEqual(k.voiceRoom, k.chatRoom);
  assert.throws(() => spaceKeys('xyz'));
});

test('seal/open: AES-GCM with the ghost-net-v1 AAD, opened by WebCrypto as voice.js opens; and the other way', async () => {
  const k = spaceKeys(SEED);
  const webKey = await crypto.subtle.importKey('raw', k.key, 'AES-GCM', false, ['encrypt', 'decrypt']);
  const aad = new TextEncoder().encode('ghost-net-v1');
  const sealed = sealJson(k.key, { t: 'me', n: 'Discord' });
  const clear = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: sealed.subarray(0, 12), additionalData: aad, tagLength: 128 }, webKey, sealed.subarray(12));
  assert.deepEqual(JSON.parse(new TextDecoder().decode(clear)), { t: 'me', n: 'Discord' });

  const iv = randomBytes(12);
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData: aad, tagLength: 128 }, webKey, new TextEncoder().encode('{"t":"hi"}')));
  assert.deepEqual(openJson(k.key, Buffer.concat([iv, ct])), { t: 'hi' });

  const changed = Buffer.from(sealed);
  changed[20] ^= 1;
  assert.equal(open(k.key, changed), null);
  assert.equal(open(spaceKeys('cd'.repeat(32)).key, sealed), null);
  assert.equal(open(k.key, Buffer.alloc(5)), null);
  assert.deepEqual(open(k.key, seal(k.key, Buffer.from('x'))), Buffer.from('x'));
});

test('room frames: out [2][room][sealed]; in [2][room][from][sealed]', () => {
  const k = spaceKeys(SEED);
  const out = roomFrame(k.voiceRoom, Buffer.from([9, 9]));
  assert.equal(out[0], 2);
  assert.equal(out.length, 1 + 16 + 2);
  const from = 'ef'.repeat(16);
  const incoming = Buffer.concat([out.subarray(0, 17), Buffer.from(from, 'hex'), Buffer.from([1, 2, 3])]);
  assert.deepEqual(parseRoomFrame(new Uint8Array(incoming)), { room: k.voiceRoom, from, sealed: Buffer.from([1, 2, 3]) });
  assert.equal(parseRoomFrame(Buffer.from([1, 2, 3])), null);
});

test('highestOpus changes an SDP exactly as voice.js does', () => {
  const sdp = ['v=0', 'm=audio 9 UDP/TLS/RTP/SAVPF 111 0', 'a=rtpmap:111 opus/48000/2', 'a=fmtp:111 minptime=10;useinbandfec=1', 'a=rtpmap:0 PCMU/8000', 'm=audio 9 UDP/TLS/RTP/SAVPF 96', 'a=rtpmap:96 OPUS/48000/2', ''].join('\r\n');
  assert.equal(highestOpus(sdp), page.highestOpus(sdp));
  assert.match(highestOpus(sdp), /a=fmtp:96 minptime=10;useinbandfec=1;stereo=1;sprop-stereo=1;maxaveragebitrate=510000/);
  assert.equal(highestOpus('v=0\r\n'), 'v=0\r\n');
});

test('identity and sign-in: the hub (checking the signature as hub.dart does) lets the bridge in; the key is kept', async () => {
  const me = makeIdentity();
  assert.match(me.id, /^[0-9a-f]{32}$/);
  assert.equal(me.pub.length, 33);
  assert.ok(me.pub[0] === 2 || me.pub[0] === 3);
  const again = makeIdentity(me.pem);
  assert.equal(again.id, me.id);
  assert.notEqual(makeIdentity().id, me.id);

  const fake = new FakeHub();
  const hub = new Hub({ url: 'ws://fake', me, connect: () => fake.connect() });
  const states = [];
  hub.on('state', (up) => states.push(up));
  hub.start();
  await until(() => hub.up, 2000, 'sign-in');
  assert.equal(fake.refusedSignIns, 0);
  // A forged sign-in (someone else's id) is refused by the same check.
  const forger = { ...makeIdentity(), id: me.id };
  const bad = new Hub({ url: 'ws://fake', me: forger, connect: () => fake.connect(), retryMs: 60_000 });
  bad.start();
  await until(() => fake.refusedSignIns === 1, 2000, 'refusal');
  assert.equal(bad.up, false);
  bad.stop();

  // Rooms are joined again after the hub drops the connection.
  const k = spaceKeys(SEED);
  assert.deepEqual(await hub.join(k.voiceRoom, k.voiceToken), []);
  hub.retryMs = 5;
  fake.dropAll();
  await until(() => !hub.up, 2000, 'drop');
  await until(() => hub.up && fake.members(k.voiceRoom).includes(me.id), 3000, 'rejoin');
  assert.deepEqual(states.slice(0, 3), [true, false, true]);
  hub.stop();
});

test('a join still waiting fails when its room is left or the hub stopped, and never hangs', async () => {
  // A hub that is never reached, so every join waits.
  const hub = new Hub({ url: 'ws://fake', me: makeIdentity(), connect: () => { throw new Error('down'); }, retryMs: 60_000 });
  hub.start();
  const k = spaceKeys(SEED);
  const settled = (p) => Promise.race([p.then(() => 'joined', (e) => e.message), new Promise((r) => setTimeout(() => r('still waiting'), 200))]);
  const left = hub.join(k.voiceRoom, k.voiceToken);
  const other = hub.join(k.chatRoom, k.chatToken);
  hub.leave(k.voiceRoom);
  assert.equal(await settled(left), 'left the room');
  hub.stop();
  assert.equal(await settled(other), 'hub stopped');
});
