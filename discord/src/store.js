// The links: which Uplink token reads which server. On disk as SHA-256 hashes of the tokens, never the tokens
// themselves, so the file is no use to whoever reads it. Written whole to a temporary file and renamed over the old.
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { closeSync, existsSync, fsyncSync, mkdirSync, openSync, readFileSync, renameSync, writeSync } from 'node:fs';
import { dirname, join } from 'node:path';

/** What a token looks like: checked before anything is hashed or compared. */
export const TOKEN_SHAPE = /^[0-9a-f]{32}$/;
const hash = (token) => createHash('sha256').update(token, 'utf8').digest();

export class TokenStore {
  /** file: the JSON file's path, or null to keep everything in memory (tests). */
  constructor(file, { now = Date.now } = {}) {
    this.file = file;
    this.now = now;
    this.links = new Map(); // hash hex -> { hash (Buffer), guild, at }
    if (file && existsSync(file)) {
      const data = JSON.parse(readFileSync(file, 'utf8'));
      for (const link of data.links ?? []) {
        if (typeof link.hash === 'string' && /^[0-9a-f]{64}$/.test(link.hash) && typeof link.guild === 'string') {
          this.links.set(link.hash, { hash: Buffer.from(link.hash, 'hex'), guild: link.guild, at: link.at ?? 0 });
        }
      }
    }
  }

  /** The store kept in links.json under `dir`, which is made (the owner's alone) if it is not there. */
  static open(dir, options) {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    return new TokenStore(join(dir, 'links.json'), options);
  }

  /** A new token for this server: 32 lowercase hex digits, returned once and never kept. */
  add(guildId) {
    const token = randomBytes(16).toString('hex');
    const h = hash(token);
    this.links.set(h.toString('hex'), { hash: h, guild: guildId, at: this.now() });
    this.save();
    return token;
  }

  /** The server a token reads, or null. The comparison takes the same time however close a guess is. */
  guildOf(token) {
    if (typeof token !== 'string' || !TOKEN_SHAPE.test(token)) return null;
    // Every stored hash is compared with the token's, in constant time, and none is skipped: how long this takes
    // says nothing about how close a guess came. (The file holds hashes, so the comparison is of hashes.)
    const h = hash(token);
    let found = null;
    for (const link of this.links.values()) {
      if (timingSafeEqual(link.hash, h) && found === null) found = link.guild;
    }
    return found;
  }

  /** Every token of a server revoked; how many there were. */
  revokeGuild(guildId) {
    let n = 0;
    for (const [k, v] of this.links) if (v.guild === guildId) { this.links.delete(k); n++; }
    if (n) this.save();
    return n;
  }

  countGuild(guildId) {
    let n = 0;
    for (const v of this.links.values()) if (v.guild === guildId) n++;
    return n;
  }

  /** The whole file written anew: to a temporary file, flushed to disk, then renamed over the old one. */
  save() {
    if (!this.file) return;
    mkdirSync(dirname(this.file), { recursive: true, mode: 0o700 });
    const body = JSON.stringify({ version: 1, links: [...this.links].map(([h, v]) => ({ hash: h, guild: v.guild, at: v.at })) }, null, 1);
    const tmp = `${this.file}.${process.pid}.tmp`;
    const fd = openSync(tmp, 'w', 0o600);
    try {
      writeSync(fd, body);
      fsyncSync(fd);
    } finally {
      closeSync(fd);
    }
    renameSync(tmp, this.file);
  }
}
