// The bridges: for each Discord voice channel an Uplink user has pressed, the bot in that channel and the bridge in the
// matching Uplink space at once, with sound and chat carried both ways. Nothing here imports discord.js: the bot hands
// in `discord`, which does the Discord half (voice.js), and everything else is this folder's.
//
//   discord.joinVoice(guildId, channelId, { opus(userId, packet), speaking(userId, on), lost() })
//       -> Promise<{ play(opus), quiet(), destroy() }>       (rejoins once by itself; lost() when it gives up)
//   discord.people(guildId, channelId, speaking: Set)  -> the space's {t:'dc'} list (mapping.js dcPeople)
//   discord.setNickname(guildId, text | null)          -> Promise (skips quietly without Change Nickname)
//   discord.postText(guildId, channelId, { name, text }) -> Promise (webhook, else as the bot)
//
// Logs: server and channel ids, counts and outcomes. Never a seed, a key, a name or a message.
import { AudioEngine, Ticker } from './audio.js';
import { nicknameFor } from './mapping.js';
import { GhostSpace } from './space.js';
import { BridgeStore } from './store.js';

/** How long a bridge stays with nobody from Uplink in its space. */
export const LEAVE_AFTER_MS = 30_000;
/** How often the Discord channel's people are told to the space again, besides at every change. */
export const PEOPLE_EVERY_MS = 5_000;

/** Why a bridge could not be made, by `code`, which http.js turns into the answer's status. */
export class BridgeError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code; // 'voice' (could not join on Discord) | 'hub' (the relay is not reachable)
  }
}

/** The promise, or a rejection with onTimeout()'s error if it has not settled within `ms`. */
const withTimeout = (promise, ms, onTimeout) => {
  let timer;
  return Promise.race([promise, new Promise((_, fail) => { timer = setTimeout(() => fail(onTimeout()), ms); })]).finally(() => clearTimeout(timer));
};

/** One bridged channel: the bot's voice connection there, the bridge's place in the Uplink space, and the sound
 * engine between them. owner: the Bridges, for the things handed in (hub, codec, discord, timers, log). */
class Bridge {
  constructor(owner, guildId, channelId, seed) {
    this.owner = owner;
    this.guildId = guildId;
    this.channelId = channelId;
    this.seed = seed;
    // speaking: the Discord users talking now. names: the Uplink members in the space, for the bot's nickname.
    // speakingOut: whether the bot shows as speaking on Discord.
    this.speaking = new Set();
    this.names = [];
    this.stopped = false;
    this.speakingOut = false;
    this.leaveTimer = null;
    this.peopleTimer = null;
    this.tickErrors = 0;
  }

  get tag() {
    return `${this.guildId}/${this.channelId}`;
  }

  /** Joins the Discord channel and the Uplink space at once. If either fails, or the bridge is stopped meanwhile, the
   * other is left again and a BridgeError thrown; once both are in, the sound, the people list and the leave clock
   * start. */
  async start() {
    const o = this.owner;
    this.engine = new AudioEngine({ codec: o.codec });
    this.space = new GhostSpace({
      hub: o.hub,
      seed: this.seed,
      peers: o.peers,
      now: o.now,
      log: (m) => o.log(`bridge ${this.tag}: ${m}`),
      on: {
        members: (list) => this.membersChanged(list),
        audio: (id, opus) => this.engine.feedGhost(id, opus),
        peerUp: (id) => this.engine.addRecipient(id),
        peerDown: (id) => this.engine.dropGhost(id),
        chat: (m) => this.fromGhostChat(m),
      },
    });
    const voice = o.discord.joinVoice(this.guildId, this.channelId, {
      opus: (userId, packet) => this.engine.feedDiscord(userId, packet),
      speaking: (userId, on) => this.speakingChanged(userId, on),
      lost: () => this.stop('disconnected from Discord voice'),
    });
    const space = withTimeout(this.space.open(), o.joinTimeoutMs, () => new BridgeError('hub', 'the relay hub did not let the bridge in'));
    const [v, s] = await Promise.allSettled([voice, space]);
    // Stopped while joining (Discord dropped the voice connection meanwhile, or the bot is shutting down): leave both
    // again, and say so, or ensure() would answer the seed of a bridge that is not there. Before the check below,
    // since stopping also ends the wait for the space.
    if (this.stopped) {
      if (v.status === 'fulfilled') v.value.destroy();
      await this.space.close();
      throw new BridgeError('voice', 'the bridge was stopped while joining');
    }
    if (v.status === 'rejected' || s.status === 'rejected') {
      if (v.status === 'fulfilled') v.value.destroy();
      await this.space.close();
      this.stopped = true;
      const e = v.status === 'rejected' ? v.reason : s.reason;
      throw e instanceof BridgeError ? e : new BridgeError(v.status === 'rejected' ? 'voice' : 'hub', e?.message ?? String(e));
    }
    this.voice = v.value;
    this.ticker = o.ticker(() => this.tick());
    this.ticker.start();
    this.peopleTimer = o.setInterval(() => this.sendPeople(), PEOPLE_EVERY_MS);
    this.sendPeople();
    this.armLeave();
  }

  /** Every 20 ms: the Uplink mix played into Discord (or the bot shown quiet), and each Uplink member sent their mix.
   * A failure is logged once in 500, so a broken stream cannot fill the log. */
  tick() {
    if (this.stopped || !this.voice) return;
    try {
      const { discord, ghost } = this.engine.tick();
      if (discord) {
        this.voice.play(discord);
        this.speakingOut = true;
      } else if (this.speakingOut) {
        this.voice.quiet();
        this.speakingOut = false;
      }
      for (const [id, opus] of ghost) this.space.sendAudio(id, opus);
    } catch (e) {
      if (this.tickErrors++ % 500 === 0) this.owner.log(`bridge ${this.tag}: sound failed (${this.tickErrors}): ${e?.message ?? e}`);
    }
  }

  /** The Discord channel's people, as they are now, told to the space; whoever has left stops being mixed. */
  sendPeople() {
    if (this.stopped || !this.space) return;
    const people = this.owner.discord.people(this.guildId, this.channelId, this.speaking);
    const ids = new Set(people.map((p) => p.id));
    for (const id of [...this.engine.discordIn.keys()]) if (!ids.has(id)) this.engine.dropDiscord(id);
    for (const id of [...this.speaking]) if (!ids.has(id)) this.speaking.delete(id);
    this.space.setPeople(people);
  }

  /** A Discord user began or stopped talking: the space is told at once. */
  speakingChanged(userId, on) {
    const had = this.speaking.has(userId);
    if (on === had) return;
    if (on) this.speaking.add(userId);
    else this.speaking.delete(userId);
    this.sendPeople();
  }

  /** The Uplink members in the space changed: the leave clock and the bot's nickname follow. */
  membersChanged(list) {
    this.names = list.map((m) => m.name);
    this.armLeave();
    this.owner.nicknameChanged(this.guildId);
  }

  /** No Uplink member in the call: leave in 30 s unless one comes. Someone there: stay. */
  armLeave() {
    if (this.stopped) return;
    const empty = !this.space || this.space.members.size === 0;
    if (empty && !this.leaveTimer) {
      this.leaveTimer = this.owner.setTimer(() => {
        this.leaveTimer = null;
        if (this.space?.members.size === 0) this.stop('nobody from Uplink for 30 s');
      }, LEAVE_AFTER_MS);
    } else if (!empty && this.leaveTimer) {
      this.owner.clearTimer(this.leaveTimer);
      this.leaveTimer = null;
    }
  }

  /** A join request again: the leave clock starts over if nobody is there yet. */
  touched() {
    if (this.leaveTimer) {
      this.owner.clearTimer(this.leaveTimer);
      this.leaveTimer = null;
    }
    this.armLeave();
  }

  /** An Uplink member's message, posted in the Discord channel; a failure is logged and nothing more. */
  fromGhostChat({ name, text }) {
    this.owner.discord.postText(this.guildId, this.channelId, { name: name || 'Uplink', text }).catch((e) => this.owner.log(`bridge ${this.tag}: posting to Discord failed: ${e?.code ?? e?.message ?? e}`));
  }

  /** A Discord message, said in the space's chat. */
  fromDiscordChat({ name, text }) {
    if (this.stopped || !this.space) return false;
    return this.space.sendChat({ name, text });
  }

  /** Leaves the channel and the space, once, and tells the owner. */
  async stop(why) {
    if (this.stopped) return;
    this.stopped = true;
    this.owner.log(`bridge ${this.tag}: leaving (${why})`);
    this.owner.clearTimer(this.leaveTimer);
    this.owner.clearInterval(this.peopleTimer);
    this.ticker?.stop();
    try {
      this.voice?.destroy();
    } catch {}
    await this.space?.close().catch(() => {});
    this.owner.ended(this);
  }
}

/** Every bridge the bot has, by server and channel. The clock, the timers and the ticker come in so tests can
 * stand in for them. */
export class Bridges {
  constructor({
    store, hub, peers, codec, discord, log = () => {}, now = Date.now,
    setTimer = setTimeout, clearTimer = clearTimeout, setInterval: every = setInterval, clearInterval: stopEvery = clearInterval,
    ticker = (f) => new Ticker(f), joinTimeoutMs = 10_000, nicknameDelayMs = 1500,
  }) {
    Object.assign(this, { store, hub, peers, codec, discord, log, now, setTimer, clearTimer, ticker, joinTimeoutMs, nicknameDelayMs });
    this.setInterval = every;
    this.clearInterval = stopEvery;
    this.bridges = new Map(); // "guild:channel" -> Bridge
    this.starting = new Map(); // "guild:channel" -> { bridge, done: Promise }
    this.nicknames = new Map(); // guild -> what it was last set to
    this.nicknameTimers = new Map();
  }

  /** The channel ids the bridge is in now (for /state's "bridged"). */
  bridged(guildId) {
    const out = new Set();
    for (const b of this.bridges.values()) if (b.guildId === guildId && !b.stopped) out.add(b.channelId);
    return out;
  }

  /**
   * The bot in the Discord channel and the bridge in its space, made sure of (it stays as it is when it already is).
   * { seed, bridge: the bridge's hub id }. Throws BridgeError when either half cannot be joined.
   */
  async ensure(guildId, channelId) {
    const key = BridgeStore.key(guildId, channelId);
    const seed = this.store.seedFor(guildId, channelId);
    const have = this.bridges.get(key);
    if (have && !have.stopped) {
      have.touched();
      return { seed, bridge: this.hub.me.id };
    }
    let starting = this.starting.get(key)?.done;
    if (!starting) {
      // A bot is in one voice channel per server at most: another bridged channel there gives way only when nobody
      // from Uplink is in it.
      for (const k of this.starting.keys()) if (k.startsWith(`${guildId}:`)) throw new BridgeError('busy', 'another channel on this server is being bridged');
      for (const b of [...this.bridges.values()]) {
        if (b.guildId !== guildId || b.channelId === channelId || b.stopped) continue;
        if (b.space.members.size > 0) throw new BridgeError('busy', 'another channel on this server is bridged');
        await b.stop('another channel was asked for');
      }
      const b = new Bridge(this, guildId, channelId, seed);
      starting = b.start().then(() => {
        if (!b.stopped) this.bridges.set(key, b);
        this.log(`bridge ${b.tag}: in (${this.bridges.size} bridged)`);
      }).finally(() => this.starting.delete(key));
      this.starting.set(key, { bridge: b, done: starting });
    }
    await starting;
    return { seed, bridge: this.hub.me.id };
  }

  /** The running bridge of a channel, or null. */
  find(guildId, channelId) {
    const b = this.bridges.get(`${guildId}:${channelId}`);
    return b && !b.stopped ? b : null;
  }

  /** A bridge has stopped: forgotten, and its people's names taken out of the bot's nickname. */
  ended(b) {
    const key = `${b.guildId}:${b.channelId}`;
    if (this.bridges.get(key) === b) this.bridges.delete(key);
    this.nicknameChanged(b.guildId);
  }

  /** Someone came, went, muted or deafened in a Discord voice channel. */
  voiceChanged(guildId, channelId) {
    this.find(guildId, channelId)?.sendPeople();
  }

  /** A message in a Discord channel (already filtered by mapping.js discordToGhost). */
  discordText(guildId, channelId, message) {
    return this.find(guildId, channelId)?.fromDiscordChat(message) ?? false;
  }

  /** The bot's nickname on a server, for everyone from Uplink in its calls there; changed at most once a delay. */
  nicknameChanged(guildId) {
    if (this.nicknameTimers.has(guildId)) return;
    this.nicknameTimers.set(guildId, this.setTimer(() => {
      this.nicknameTimers.delete(guildId);
      const names = [];
      for (const b of this.bridges.values()) if (b.guildId === guildId && !b.stopped) names.push(...b.names);
      const text = nicknameFor(names);
      if ((this.nicknames.get(guildId) ?? null) === text) return;
      this.nicknames.set(guildId, text);
      Promise.resolve(this.discord.setNickname(guildId, text)).catch(() => {});
    }, this.nicknameDelayMs));
  }

  /** Every running bridge stopped (the bot is shutting down), and every one still joining: those are waited for, so
   * a voice connection made meanwhile is closed too. */
  async stopAll(why) {
    const starting = [...this.starting.values()];
    await Promise.all([...this.bridges.values(), ...starting.map((s) => s.bridge)].map((b) => b.stop(why)));
    await Promise.all(starting.map((s) => s.done.catch(() => {})));
  }
}
