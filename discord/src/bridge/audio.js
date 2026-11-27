// The bridge's sound, every 20 ms: what each Discord speaker and each Uplink member sent, decoded and queued; one mix of
// the Uplink members for Discord (sent only while someone is talking); and for each Uplink member a mix of Discord and
// the other Uplink members, never their own voice. The codec comes in (opus.js in the bot, a stand-in in tests) and so
// does the clock: tick() is called by Ticker below in the bot and by hand in tests.
import { FRAME_MS, Gate, PcmQueue, mix, mixMinusSelf } from './mixer.js';

/** One bridge's sound: packets fed in from both sides as they come, mixed and encoded a frame at a time by tick(). */
export class AudioEngine {
  constructor({ codec, toDiscordBitrate = 96000, toGhostBitrate = 128000 }) {
    this.codec = codec;
    this.toGhostBitrate = toGhostBitrate;
    this.discordIn = new Map(); // user id -> { decoder, queue }
    this.ghostIn = new Map(); // member id -> { decoder, queue }
    this.out = new Map(); // member id -> encoder: the Uplink members sound is sent to
    this.toDiscord = codec.encoder({ bitrate: toDiscordBitrate });
    this.gate = new Gate();
    this.tail = 0; // silence frames still to send to Discord after the gate closes
    this.decodeErrors = 0;
  }

  /** A speaker's decoder and queue, made the first time they are heard from. */
  source(map, id) {
    let s = map.get(id);
    if (!s) {
      s = { decoder: this.codec.decoder(), queue: new PcmQueue() };
      map.set(id, s);
    }
    return s;
  }

  /** A packet decoded onto its speaker's queue; one that will not decode is counted and dropped. */
  feed(map, id, packet) {
    const s = this.source(map, id);
    try {
      s.queue.push(s.decoder.decode(packet));
    } catch {
      this.decodeErrors++;
    }
  }

  /** An Opus packet from a Discord speaker (already out of Discord's encryption). */
  feedDiscord(userId, packet) {
    this.feed(this.discordIn, userId, packet);
  }

  /** An Opus packet from an Uplink member's WebRTC track. */
  feedGhost(memberId, packet) {
    this.feed(this.ghostIn, memberId, packet);
  }

  /** A Discord speaker gone from the channel. */
  dropDiscord(userId) {
    this.discordIn.delete(userId);
  }

  /** An Uplink member gone: nothing more from them, nothing more to them. */
  dropGhost(memberId) {
    this.ghostIn.delete(memberId);
    this.out.delete(memberId);
  }

  /** An Uplink member to send sound to (their connection is up). */
  addRecipient(memberId) {
    if (!this.out.has(memberId)) this.out.set(memberId, this.codec.encoder({ bitrate: this.toGhostBitrate }));
  }

  removeRecipient(memberId) {
    this.out.delete(memberId);
  }

  /**
   * The next 20 ms: { discord: Opus packet or null (nothing to send: Discord shows us not speaking), ghost: Map
   * member id -> Opus packet }.
   */
  tick() {
    const discordFrames = [];
    for (const s of this.discordIn.values()) discordFrames.push(s.queue.take());
    const live = discordFrames.filter(Boolean);
    const fromDiscord = live.length ? mix(live) : null;

    const ghostFrames = new Map();
    for (const [id, s] of this.ghostIn) ghostFrames.set(id, s.queue.take());

    // Uplink -> Discord: every Uplink member mixed, sent while the gate is open and for five frames of silence after.
    const ghostLive = [...ghostFrames.values()].filter(Boolean);
    const forDiscord = ghostLive.length ? mix(ghostLive) : null;
    let discord = null;
    if (this.gate.next(forDiscord) && forDiscord) {
      discord = this.toDiscord.encode(forDiscord);
      this.tail = 5;
    } else if (this.tail > 0) {
      this.tail--;
      discord = this.codec.silence;
    }

    // Discord -> Uplink: each member's own mix (all of Discord, the other Uplink members), never their own voice.
    const ghost = new Map();
    const mixes = mixMinusSelf(fromDiscord, ghostFrames, [...this.out.keys()]);
    for (const [id, frame] of mixes) ghost.set(id, frame ? this.out.get(id).encode(frame) : this.codec.silence);
    return { discord, ghost };
  }
}

/**
 * Calls [f] every 20 ms, kept to the wall clock (a late call is followed by a sooner one, never a drift); if the
 * process falls more than 200 ms behind it skips ahead rather than bursting.
 */
export class Ticker {
  constructor(f, { now = () => performance.now(), periodMs = FRAME_MS } = {}) {
    this.f = f;
    this.now = now;
    this.period = periodMs;
    this.timer = null;
  }

  start() {
    if (this.timer) return;
    // this.next: when the next call is due, counted on from the last due time and not from when the timer fired.
    this.next = this.now() + this.period;
    const run = () => {
      const t = this.now();
      if (t - this.next > 200) this.next = t;
      while (this.next <= t + 1) {
        this.next += this.period;
        try {
          this.f();
        } catch {}
      }
      this.timer = setTimeout(run, Math.max(0, this.next - this.now()));
    };
    this.timer = setTimeout(run, this.period);
  }

  stop() {
    clearTimeout(this.timer);
    this.timer = null;
  }
}
