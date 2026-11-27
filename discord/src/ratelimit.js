// A fixed window per key: at most `limit` hits in each `windowMs`. Used for claim attempts, per address and overall.
export class RateLimit {
  constructor({ limit, windowMs = 60_000, now = Date.now }) {
    this.limit = limit;
    this.windowMs = windowMs;
    this.now = now;
    this.hits = new Map(); // key -> { start, count }
  }

  /** true when this hit is allowed (and it is counted); false when the key is over its limit. */
  hit(key) {
    const t = this.now();
    // Ended windows are swept only once the map is large, so it cannot grow without bound.
    if (this.hits.size > 10_000) for (const [k, v] of this.hits) if (t - v.start >= this.windowMs) this.hits.delete(k);
    let entry = this.hits.get(key);
    if (!entry || t - entry.start >= this.windowMs) {
      entry = { start: t, count: 0 };
      this.hits.set(key, entry);
    }
    entry.count++;
    return entry.count <= this.limit;
  }

  /** Seconds until the key's window ends. */
  retryAfter(key) {
    const entry = this.hits.get(key);
    return entry ? Math.max(1, Math.ceil((entry.start + this.windowMs - this.now()) / 1000)) : 1;
  }
}
