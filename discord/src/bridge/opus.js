// Opus for the bridge: @evan/opus (libopus; its own prebuilt binary where there is one for the machine, else the same
// libopus as WebAssembly, so it never needs a compiler). 48 kHz stereo both ways.
import { createRequire } from 'node:module';
import { CHANNELS, RATE, int16, bytesOf } from './mixer.js';

const require = createRequire(import.meta.url);
const { Encoder, Decoder } = require('@evan/opus');

/** Opus's own 20 ms of silence (what Discord itself sends before it stops). */
export const SILENCE = Buffer.from([0xf8, 0xff, 0xfe]);

/** The codec AudioEngine is given: decoders from Opus packets to 16-bit samples, encoders back (20 ms a packet), and
 * the packet that stands for silence. */
export const opusCodec = {
  silence: SILENCE,
  decoder() {
    const d = new Decoder({ channels: CHANNELS, sample_rate: RATE });
    return { decode: (packet) => int16(d.decode(packet)) };
  },
  encoder({ bitrate = 96000 } = {}) {
    const e = new Encoder({ channels: CHANNELS, sample_rate: RATE, application: 'audio' });
    e.bitrate = bitrate;
    return { encode: (samples) => Buffer.from(e.encode(bytesOf(samples))) };
  },
};
