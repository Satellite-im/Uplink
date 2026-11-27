// Sound as numbers: 48 kHz stereo, 16-bit, interleaved, in 20 ms frames (960 samples a channel, 1920 numbers).
// A small queue per speaker to even out how packets arrive, mixing by adding and clipping, and each Uplink member's
// mix without their own voice in it. Pure: no codec, no network, no clock.

export const RATE = 48000;
export const CHANNELS = 2;
export const FRAME = 960; // samples a channel in 20 ms
export const FRAME_LEN = FRAME * CHANNELS;
export const FRAME_MS = 20;

/**
 * What one speaker has sent, waiting to be mixed. It starts giving frames once it holds [start] frames (a little
 * slack for packets that come late), never holds more than [max] (the oldest go: lateness is not allowed to grow),
 * and after running dry waits to fill to [start] again.
 */
export class PcmQueue {
  constructor({ start = 2, max = 6 } = {}) {
    this.start = start * FRAME_LEN;
    this.max = max * FRAME_LEN;
    this.buf = new Int16Array(this.max + FRAME_LEN * 6);
    this.len = 0;
    this.playing = false;
  }

  get frames() {
    return Math.floor(this.len / FRAME_LEN);
  }

  /** Decoded samples added at the end; what would take the queue past [max] is dropped from the front. */
  push(samples) {
    let s = samples;
    if (s.length > this.max) s = s.subarray(s.length - this.max);
    if (this.len + s.length > this.max) {
      const drop = this.len + s.length - this.max;
      this.buf.copyWithin(0, drop, this.len);
      this.len -= drop;
    }
    this.buf.set(s, this.len);
    this.len += s.length;
  }

  /** The next 20 ms, or null (nothing to play yet, or ran dry). */
  take() {
    if (!this.playing) {
      if (this.len < this.start) return null;
      this.playing = true;
    }
    if (this.len < FRAME_LEN) {
      this.playing = false;
      return null;
    }
    const out = this.buf.slice(0, FRAME_LEN);
    this.buf.copyWithin(0, FRAME_LEN, this.len);
    this.len -= FRAME_LEN;
    return out;
  }
}

/** A sum held to what 16 bits can carry. */
const clip = (v) => (v > 32767 ? 32767 : v < -32768 ? -32768 : v);

/** Every frame added up into a 32-bit sum (so nothing clips before the end). Null frames are silence. */
export function sum(frames, len = FRAME_LEN) {
  const total = new Int32Array(len);
  for (const f of frames) {
    if (!f) continue;
    for (let i = 0; i < len; i++) total[i] += f[i];
  }
  return total;
}

/** A sum, minus one frame (a member's own voice), clipped into 16 bits. */
export function clipTo16(total, minus = null) {
  const out = new Int16Array(total.length);
  for (let i = 0; i < total.length; i++) out[i] = clip(minus ? total[i] - minus[i] : total[i]);
  return out;
}

/** The frames mixed: summed and clipped. */
export const mix = (frames, len = FRAME_LEN) => clipTo16(sum(frames, len));

/**
 * One mix for each Uplink member: everyone from Discord ([discord], already mixed, or null) and every other Uplink
 * member ([ghost]: id -> frame or null), never their own voice. Map id -> Int16Array, or null where it is silence.
 */
export function mixMinusSelf(discord, ghost, recipients) {
  const frames = [...ghost.values()].filter(Boolean);
  const anything = Boolean(discord) || frames.length > 0;
  const total = anything ? sum([discord, ...frames]) : null;
  const out = new Map();
  for (const id of recipients) {
    const own = ghost.get(id) ?? null;
    const others = (discord ? 1 : 0) + frames.length - (own ? 1 : 0);
    out.set(id, others > 0 ? clipTo16(total, own) : null);
  }
  return out;
}

/** How loud a frame is: its root mean square, 0 to 32768. */
export function rms(frame) {
  if (!frame) return 0;
  let s = 0;
  for (let i = 0; i < frame.length; i++) s += frame[i] * frame[i];
  return Math.sqrt(s / frame.length);
}

/**
 * Whether someone is talking, from how loud each frame is: on at once above [threshold], off only after [hangFrames]
 * quieter frames in a row (so the ends of words are not cut). Apps send even silence as packets, so a packet
 * arriving says nothing about talking.
 */
export class Gate {
  constructor({ threshold = 120, hangFrames = 15 } = {}) {
    this.threshold = threshold;
    this.hangFrames = hangFrames;
    // Quiet frames in a row since the last loud one; Infinity until the first, so the gate starts closed.
    this.quiet = Infinity;
  }

  /** true while the gate is open after this frame. */
  next(frame) {
    if (rms(frame) >= this.threshold) this.quiet = 0;
    else this.quiet++;
    return this.quiet <= this.hangFrames;
  }
}

/** Decoded bytes (little-endian, as on every machine this runs on) as 16-bit numbers: a copy, so always aligned. */
export function int16(bytes) {
  const u8 = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  const copy = new Uint8Array(u8.byteLength & ~1);
  copy.set(u8.subarray(0, copy.length));
  return new Int16Array(copy.buffer);
}

/** 16-bit numbers as the bytes a codec takes. */
export const bytesOf = (samples) => new Uint8Array(samples.buffer, samples.byteOffset, samples.byteLength);

/** Mono samples made stereo (each sample twice); stereo unchanged. */
export function toStereo(samples, channels) {
  if (channels === 2) return samples;
  const out = new Int16Array(samples.length * 2);
  for (let i = 0; i < samples.length; i++) out[2 * i] = out[2 * i + 1] = samples[i];
  return out;
}
