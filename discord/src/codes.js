// Link codes: six characters a server's admin reads out of an ephemeral /ghost link reply and types into the app.
// Kept in memory only (a restart forgets them; the admin runs /ghost link again). One use, ten minutes.
import { randomInt } from 'node:crypto';

/** No 0/O, 1/I/L: nothing that reads as something else. */
export const ALPHABET = '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
export const CODE_LENGTH = 6;
export const CODE_TTL_MS = 10 * 60 * 1000;
/** Codes a server may have waiting at once; the oldest goes when a new one is made past it. */
const PER_GUILD = 5;

/** The codes waiting to be claimed. `now` and `ttl` are for tests. */
export class Codes {
  constructor({ now = Date.now, ttl = CODE_TTL_MS } = {}) {
    this.now = now;
    this.ttl = ttl;
    this.byCode = new Map(); // code -> { guildId, expires }
  }

  /** A new code for this server. */
  issue(guildId) {
    this.prune();
    const mine = [...this.byCode].filter(([, v]) => v.guildId === guildId);
    for (const [code] of mine.slice(0, Math.max(0, mine.length - PER_GUILD + 1))) this.byCode.delete(code);
    let code;
    do {
      code = '';
      for (let i = 0; i < CODE_LENGTH; i++) code += ALPHABET[randomInt(ALPHABET.length)];
    } while (this.byCode.has(code));
    this.byCode.set(code, { guildId, expires: this.now() + this.ttl });
    return code;
  }

  /** The server a code was made for, and the code is used up; null for an unknown, expired or used one. */
  take(raw) {
    this.prune();
    if (typeof raw !== 'string') return null;
    const code = raw.trim().toUpperCase();
    if (code.length !== CODE_LENGTH || [...code].some((c) => !ALPHABET.includes(c))) return null;
    const entry = this.byCode.get(code);
    if (!entry) return null;
    this.byCode.delete(code);
    return entry.guildId;
  }

  /** Every waiting code of a server forgotten (/ghost unlink). */
  dropGuild(guildId) {
    for (const [code, v] of this.byCode) if (v.guildId === guildId) this.byCode.delete(code);
  }

  /** Expired codes forgotten; run before every read. */
  prune() {
    const t = this.now();
    for (const [code, v] of this.byCode) if (v.expires <= t) this.byCode.delete(code);
  }

  get size() {
    this.prune();
    return this.byCode.size;
  }
}
