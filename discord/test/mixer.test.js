// Mixing and the 20 ms engine: sums clip instead of wrapping, nobody hears themselves, the queue evens out arrival,
// Discord is sent sound only while someone talks; and real Opus survives the trip.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { AudioEngine } from '../src/bridge/audio.js';
import { FRAME_LEN, Gate, PcmQueue, clipTo16, int16, mix, mixMinusSelf, rms, sum } from '../src/bridge/mixer.js';
import { SILENCE, opusCodec } from '../src/bridge/opus.js';

// A frame of one value throughout, and a frame of a sine (the same in both channels) starting [offset] samples in.
const frame = (v) => new Int16Array(FRAME_LEN).fill(v);
const sine = (hz, amp, offset = 0) => {
  const f = new Int16Array(FRAME_LEN);
  for (let i = 0; i < FRAME_LEN / 2; i++) f[2 * i] = f[2 * i + 1] = Math.round(amp * Math.sin((2 * Math.PI * hz * (offset + i)) / 48000));
  return f;
};

test('mix: adds, and clips at the 16-bit limits instead of wrapping round', () => {
  assert.equal(mix([frame(100), frame(250)])[0], 350);
  assert.equal(mix([frame(30000), frame(10000)])[5], 32767);
  assert.equal(mix([frame(-30000), frame(-10000)])[5], -32768);
  assert.equal(mix([null, frame(7)])[0], 7);
  assert.equal(mix([])[0], 0);
  assert.equal(clipTo16(sum([frame(30000), frame(10000)]), frame(10000))[0], 30000, 'minus before clipping');
});

test('mix minus self: each member hears Discord and the others, never themselves; alone with silence -> null', () => {
  const ghost = new Map([['a', frame(1000)], ['b', frame(10)], ['c', null]]);
  const out = mixMinusSelf(frame(5), ghost, ['a', 'b', 'c']);
  assert.equal(out.get('a')[0], 15);
  assert.equal(out.get('b')[0], 1005);
  assert.equal(out.get('c')[0], 1015);
  const alone = mixMinusSelf(null, new Map([['a', frame(1000)]]), ['a']);
  assert.equal(alone.get('a'), null);
  assert.equal(mixMinusSelf(null, new Map(), ['x']).get('x'), null);
});

test('queue: waits for two frames, gives 20 ms at a time, drops the oldest past six, waits again after running dry', () => {
  const q = new PcmQueue();
  q.push(frame(1));
  assert.equal(q.take(), null, 'one frame is not enough to start');
  q.push(frame(2));
  assert.equal(q.take()[0], 1);
  assert.equal(q.take()[0], 2);
  assert.equal(q.take(), null);
  q.push(frame(3));
  assert.equal(q.take(), null, 'dry: fills to two again first');
  for (let i = 4; i <= 12; i++) q.push(frame(i));
  assert.equal(q.frames, 6);
  assert.equal(q.take()[0], 7, 'the oldest went');
  // Packets of 10 ms join up into 20 ms frames.
  const r = new PcmQueue({ start: 1 });
  r.push(new Int16Array(FRAME_LEN / 2).fill(4));
  assert.equal(r.take(), null);
  r.push(new Int16Array(FRAME_LEN / 2).fill(5));
  const f = r.take();
  assert.deepEqual([f[0], f[FRAME_LEN - 1]], [4, 5]);
});

test('gate: opens at once on speech, stays open through short pauses, closes after 300 ms of quiet', () => {
  const g = new Gate();
  assert.equal(g.next(null), false);
  assert.equal(g.next(sine(440, 3000)), true);
  for (let i = 0; i < 15; i++) assert.equal(g.next(frame(0)), true);
  assert.equal(g.next(frame(0)), false);
  assert.ok(rms(sine(440, 3000)) > 2000);
  assert.equal(rms(null), 0);
});

/** "Opus" that is just the samples' bytes, so mixing can be checked exactly. */
const rawCodec = {
  silence: Buffer.from([0]),
  decoder: () => ({ decode: (b) => int16(b) }),
  encoder: () => ({ encode: (s) => Buffer.from(s.buffer.slice(s.byteOffset, s.byteOffset + s.byteLength)) }),
};
const bytes = (f) => Buffer.from(f.buffer.slice(0));

test('engine: Uplink mixed for Discord while someone talks, then five silences, then nothing', () => {
  const e = new AudioEngine({ codec: rawCodec });
  e.addRecipient('a');
  assert.deepEqual(e.tick(), { discord: null, ghost: new Map([['a', rawCodec.silence]]) });
  const loud = sine(300, 5000);
  e.feedGhost('a', bytes(loud));
  e.feedGhost('a', bytes(loud));
  const t = e.tick();
  assert.deepEqual(int16(t.discord), loud);
  assert.equal(t.ghost.get('a'), rawCodec.silence, 'a does not hear itself');
  // The second queued frame, then quiet: the gate holds 15 frames, then five silence packets, then nothing.
  e.tick();
  const outs = [];
  for (let i = 0; i < 25; i++) outs.push(e.tick().discord);
  assert.equal(outs.slice(0, 15).every((x) => x === null || x.length), true);
  assert.equal(outs.filter((x) => x === rawCodec.silence).length, 5);
  assert.equal(outs.at(-1), null);
});

test('engine: Discord speakers mixed for each Uplink member, plus the other members; dropped people stop', () => {
  const e = new AudioEngine({ codec: rawCodec });
  e.addRecipient('a');
  e.addRecipient('b');
  for (let i = 0; i < 2; i++) {
    e.feedDiscord('u1', bytes(frame(100)));
    e.feedDiscord('u2', bytes(frame(20)));
    e.feedGhost('a', bytes(frame(3)));
  }
  const { ghost } = e.tick();
  assert.equal(int16(ghost.get('a'))[0], 120);
  assert.equal(int16(ghost.get('b'))[0], 123);
  e.dropGhost('a');
  e.dropDiscord('u1');
  const next = e.tick();
  assert.equal(next.ghost.has('a'), false);
  assert.equal(int16(next.ghost.get('b'))[0], 20);
  e.feedDiscord('u3', Buffer.from([1])); // not a whole sample's worth: decodes to nothing, harmless
  e.tick();
});

test('real Opus: a 440 Hz tone through encoder and decoder comes back as a 440 Hz tone; silence decodes', () => {
  const enc = opusCodec.encoder({ bitrate: 128000 });
  const dec = opusCodec.decoder();
  let last;
  for (let i = 0; i < 25; i++) last = dec.decode(enc.encode(sine(440, 8000, i * 960)));
  assert.equal(last.length, FRAME_LEN);
  assert.ok(rms(last) > 4000, `loud enough (${rms(last)})`);
  let crossings = 0;
  for (let i = 1; i < FRAME_LEN / 2; i++) if ((last[2 * i - 2] < 0) !== (last[2 * i] < 0)) crossings++;
  assert.ok(Math.abs(crossings - 17.6) <= 2, `about 17.6 zero crossings in 20 ms at 440 Hz, got ${crossings}`);
  const quiet = opusCodec.decoder().decode(SILENCE);
  assert.ok(rms(quiet) < 50);
  // Many coders at once (one per member) do not disturb each other.
  const many = Array.from({ length: 40 }, () => [opusCodec.encoder(), opusCodec.decoder()]);
  for (const [e2, d2] of many) d2.decode(e2.encode(sine(220, 1000)));
  assert.ok(rms(dec.decode(enc.encode(sine(440, 8000, 25 * 960)))) > 4000);
});
