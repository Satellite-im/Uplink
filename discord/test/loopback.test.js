// End to end on this machine, nothing faked but Discord and the hub: the whole bridge (real WebRTC through werift,
// real Opus, the real 20 ms ticker) in a space with a stand-in Uplink app that does what lib/voice/rtc.dart does (it
// joins after the bridge, so it offers: sound and a picture, Opus asked for at its highest). The app sends a 400 Hz
// tone and a pretend Discord speaker a 650 Hz one (whole cycles in 20 ms, so one never leaks into the other's
// measure): Discord must get 400, the app 650 and never its own 400.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { Bridges } from '../src/bridge/bridge.js';
import { Hub, makeIdentity } from '../src/bridge/hub.js';
import { FRAME_LEN, rms } from '../src/bridge/mixer.js';
import { opusCodec } from '../src/bridge/opus.js';
import { highestOpus, openJson, sealJson, spaceKeys } from '../src/bridge/protocol.js';
import { weriftPeers } from '../src/bridge/rtc.js';
import { BridgeStore } from '../src/bridge/store.js';
import { FakeHub, until } from './fakehub.js';

const require = createRequire(import.meta.url);
const werift = require('werift');

const G = '100000000000000001';
const C = '400000000000000004';

/** Frame [n] (20 ms, stereo) of a steady [hz] tone, each frame carrying on where the last stopped. */
function tone(hz, n) {
  const f = new Int16Array(FRAME_LEN);
  for (let i = 0; i < FRAME_LEN / 2; i++) f[2 * i] = f[2 * i + 1] = Math.round(8000 * Math.sin((2 * Math.PI * hz * (n * 960 + i)) / 48000));
  return f;
}

/** How much of [hz] is in some frames (Goertzel on the left channel, as an amplitude): a mix that leaked the
 * wrong tone shows it, where counting zero crossings would not. */
function level(frames, hz) {
  let total = 0;
  for (const f of frames) {
    const n = f.length / 2;
    const w = (2 * Math.PI * hz) / 48000;
    let s1 = 0;
    let s2 = 0;
    for (let i = 0; i < n; i++) {
      const s = f[2 * i] + 2 * Math.cos(w) * s1 - s2;
      s2 = s1;
      s1 = s;
    }
    total += (2 * Math.sqrt(Math.max(0, s1 * s1 + s2 * s2 - 2 * Math.cos(w) * s1 * s2))) / n;
  }
  return total / frames.length;
}

test('an Uplink app and a Discord speaker hear each other through the bridge, and the app never hears itself', { timeout: 30_000 }, async () => {
  const fake = new FakeHub();
  const me = makeIdentity();
  const hub = new Hub({ url: 'ws://fake', me, connect: () => fake.connect() });
  hub.start();
  await until(() => hub.up, 2000, 'hub');

  const played = [];
  let discordOn = null;
  const discord = {
    async joinVoice(guildId, channelId, on) {
      discordOn = on;
      return { play: (o) => played.push(Buffer.from(o)), quiet() {}, destroy() {} };
    },
    people: () => [{ id: 'u1', name: 'Amy', avatar: null, muted: false, deafened: false, bot: false }],
    async setNickname() {},
    async postText() {},
  };
  const bridges = new Bridges({ store: new BridgeStore(null), hub, peers: weriftPeers({ iceServers: [] }), codec: opusCodec, discord });
  let pc = null;
  try {
  const { seed } = await bridges.ensure(G, C);
  const k = spaceKeys(seed);

  // The stand-in app.
  const appId = 'a1'.repeat(16);
  const page = fake.browser(appId);
  const say = (m) => page.ws.send(Buffer.concat([Buffer.from([2]), Buffer.from(k.voiceRoom, 'hex'), sealJson(k.key, m)]));
  pc = new werift.RTCPeerConnection({ iceServers: [], codecs: { audio: [werift.useOPUS()], video: [werift.useVP8()] } });
  const mic = new werift.MediaStreamTrack({ kind: 'audio' });
  pc.addTransceiver(mic, { direction: 'sendrecv' });
  pc.addTransceiver('video', { direction: 'sendrecv' });
  const heardFrames = [];
  const appDecoder = opusCodec.decoder();
  pc.ontrack = (e) => {
    if (e.track.kind === 'audio') e.track.onReceiveRtp.subscribe((rtp) => heardFrames.push(appDecoder.decode(rtp.payload)));
  };
  pc.onicecandidate = (e) => { if (e.candidate) say({ t: 'ice', to: me.id, c: e.candidate.toJSON() }); };
  const early = [];
  let answered = false;
  let dc = null;
  page.bin.add(async (d) => {
    const m = openJson(k.key, Buffer.from(d.subarray(33)));
    if (!m || (m.to && m.to !== appId)) return;
    if (m.t === 'dc') dc = m;
    if (m.t === 'answer') {
      await pc.setRemoteDescription({ type: 'answer', sdp: m.sdp });
      answered = true;
      for (const c of early.splice(0)) await pc.addIceCandidate(c);
    }
    if (m.t === 'ice') answered ? await pc.addIceCandidate(m.c) : early.push(m.c);
  });
  page.say({ join: k.voiceRoom, token: k.voiceToken });
  await until(() => fake.members(k.voiceRoom).includes(appId), 2000, 'app in');
  say({ t: 'me', n: 'Matt', m: false, v: false });
  const offer = await pc.createOffer();
  await pc.setLocalDescription(offer);
  say({ t: 'offer', to: me.id, sdp: highestOpus(pc.localDescription.sdp) });

  await until(() => pc.connectionState === 'connected', 10_000, 'WebRTC connected');
  const bridge = bridges.find(G, C);
  await until(() => bridge.engine.out.has(appId), 5000, 'the app is a recipient');
  assert.equal(dc.people[0].name, 'Amy');

  // 2 s of both tones, at real time.
  const enc = opusCodec.encoder({ bitrate: 128000 });
  const discordEnc = opusCodec.encoder({ bitrate: 128000 });
  let seq = 1;
  let n = 0;
  const sender = setInterval(() => {
    mic.writeRtp(new werift.RtpPacket(new werift.RtpHeader({ payloadType: 111, sequenceNumber: seq++ & 0xffff, timestamp: (n * 960) >>> 0, marker: false }), enc.encode(tone(400, n))));
    discordOn.opus('u1', discordEnc.encode(tone(650, n)));
    n++;
  }, 20);
  await new Promise((r) => setTimeout(r, 2000));
  clearInterval(sender);

  // Discord got the app's 400 Hz.
  const decoder = opusCodec.decoder();
  const toDiscord = played.map((p) => decoder.decode(p)).filter((f) => f.length === FRAME_LEN);
  assert.ok(toDiscord.length > 40, `Discord was sent ${toDiscord.length} frames`);
  const loudDiscord = toDiscord.slice(-30).filter((f) => rms(f) > 2000);
  assert.ok(loudDiscord.length > 20, `loud frames to Discord: ${loudDiscord.length}`);
  const [d400, d650] = [level(loudDiscord, 400), level(loudDiscord, 650)];
  assert.ok(d400 > 4000 && d650 < d400 / 20, `Discord heard 400 Hz at ${d400.toFixed(0)}, 650 Hz at ${d650.toFixed(0)}`);

  // The app got Discord's 650 Hz, and not its own 400.
  const loudApp = heardFrames.slice(-30).filter((f) => f.length === FRAME_LEN && rms(f) > 2000);
  assert.ok(loudApp.length > 20, `loud frames to the app: ${loudApp.length} of ${heardFrames.length}`);
  const [a400, a650] = [level(loudApp, 400), level(loudApp, 650)];
  assert.ok(a650 > 4000 && a400 < a650 / 20, `the app heard 650 Hz at ${a650.toFixed(0)}, its own 400 Hz at ${a400.toFixed(0)}`);

  } finally {
    await bridges.stopAll('test');
    await pc?.close();
    hub.stop();
  }
});
