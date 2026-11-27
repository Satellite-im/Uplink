// An in-process stand-in for Uplink's relay hub (relay/lib/hub.dart), for tests: the signed sign-in (checked as the
// hub checks it), rooms with a token each, who came and went, and room packets handed on with the sender's id put in.
// Sockets are objects with send()/onmessage, delivered on the next turn of the event loop as a network would.
import { ECDH, createHash, createPublicKey, verify } from 'node:crypto';

const hexOf = (b) => Buffer.from(b).toString('hex');

/** The hub itself. An "end" is one connection: { id (once signed in), rooms, ws, tell(message) }. */
export class FakeHub {
  constructor() {
    this.rooms = new Map(); // name -> { hash, members: Map(id -> end) }
    this.ends = new Set();
    this.refusedSignIns = 0;
    this.packets = 0;
  }

  /** A WebSocket-like object for Hub's connect(): the hub greets it, as the real one does. */
  connect() {
    const hub = this;
    const end = { id: null, hello: hexOf(Buffer.from(Array.from({ length: 16 }, (_, i) => i * 7))), rooms: new Set() };
    const ws = {
      readyState: 1,
      binaryType: 'arraybuffer',
      onmessage: null,
      onclose: null,
      onerror: null,
      send(data) {
        if (ws.readyState !== 1) return;
        const copy = typeof data === 'string' ? data : Buffer.from(data);
        setImmediate(() => hub.receive(end, copy));
      },
      close() {
        if (ws.readyState !== 1) return;
        ws.readyState = 3;
        setImmediate(() => { hub.gone(end); ws.onclose?.({}); });
      },
    };
    end.ws = ws;
    end.tell = (m) => setImmediate(() => ws.readyState === 1 && ws.onmessage?.({ data: typeof m === 'string' ? m : m instanceof Uint8Array ? m.buffer.slice(m.byteOffset, m.byteOffset + m.byteLength) : JSON.stringify(m) }));
    this.ends.add(end);
    end.tell({ hello: end.hello });
    return ws;
  }

  /** Drops every connection, as a restarting hub would. */
  dropAll() {
    for (const end of [...this.ends]) {
      end.ws.readyState = 3;
      this.gone(end);
      setImmediate(() => end.ws.onclose?.({}));
    }
  }

  /**
   * A member that is already signed in, shaped as site/join/voice.js's connectHub() result, so voice.js's own
   * Hangout and Chat classes can be run against the fake hub.
   */
  browser(id) {
    const hub = this;
    const page = { me: { id }, json: new Set(), bin: new Set() };
    const end = { id, rooms: new Set() };
    end.tell = (m) => setImmediate(() => {
      if (typeof m === 'string' || !(m instanceof Uint8Array)) { const j = typeof m === 'string' ? JSON.parse(m) : m; for (const f of page.json) f(j); } else for (const f of page.bin) f(new Uint8Array(m));
    });
    page.ws = { readyState: 1, send: (data) => setImmediate(() => hub.receive(end, typeof data === 'string' ? data : Buffer.from(data))) };
    page.say = (m) => page.ws.send(JSON.stringify(m));
    end.ws = page.ws;
    this.ends.add(end);
    return page;
  }

  /** Something an end sent: a room packet (handed to the room's other members), its sign-in, a join or a leave. */
  receive(end, data) {
    if (!this.ends.has(end)) return;
    if (typeof data !== 'string') {
      if (!end.id) return;
      if (data[0] !== 2 || data.length <= 17) return;
      const name = hexOf(data.subarray(1, 17));
      const room = this.rooms.get(name);
      if (!room || !room.members.has(end.id)) return;
      const frame = Buffer.concat([data.subarray(0, 17), Buffer.from(end.id, 'hex'), data.subarray(17)]);
      this.packets++;
      for (const m of room.members.values()) if (m !== end) m.tell(new Uint8Array(frame));
      return;
    }
    const m = JSON.parse(data);
    if (!end.id) {
      // The sign-in: the key's id must be the one claimed, and the greeting signed by it (hub.dart's check).
      const key = Buffer.from(m.key ?? '', 'base64');
      const id = hexOf(createHash('sha256').update(key).digest().subarray(0, 16));
      let ok = false;
      try {
        const raw = ECDH.convertKey(key, 'prime256v1', undefined, undefined, 'uncompressed');
        const pub = createPublicKey({ key: { kty: 'EC', crv: 'P-256', x: raw.subarray(1, 33).toString('base64url'), y: raw.subarray(33).toString('base64url') }, format: 'jwk' });
        ok = id === m.id && verify('sha256', Buffer.concat([Buffer.from('ghost-hub v1 '), Buffer.from(end.hello, 'hex')]), { key: pub, dsaEncoding: 'ieee-p1363' }, Buffer.from(m.sig ?? '', 'base64'));
      } catch {}
      if (!ok) { this.refusedSignIns++; end.tell({ ok: false, err: 'bad signature' }); return; }
      end.id = m.id;
      end.tell({ ok: true });
      return;
    }
    if (typeof m.join === 'string') this.join(end, m.join, m.token);
    else if (typeof m.leave === 'string') this.leave(end, m.leave);
  }

  /** A room is made by its first joiner, whose token it keeps (hashed); anyone with another token is refused. */
  join(end, name, token) {
    const hash = createHash('sha256').update(String(token)).digest('hex');
    let room = this.rooms.get(name);
    if (!room) this.rooms.set(name, (room = { hash, members: new Map() }));
    if (room.hash !== hash) return end.tell({ room: name, ok: false, err: 'refused' });
    const others = [...room.members.keys()].filter((id) => id !== end.id);
    room.members.set(end.id, end);
    end.rooms.add(name);
    end.tell({ room: name, ok: true, members: others });
    for (const id of others) room.members.get(id).tell({ room: name, came: end.id });
  }

  /** An end out of a room: the others are told, and an empty room is forgotten. */
  leave(end, name) {
    end.rooms.delete(name);
    const room = this.rooms.get(name);
    if (!room || room.members.get(end.id) !== end) return;
    room.members.delete(end.id);
    if (!room.members.size) this.rooms.delete(name);
    else for (const m of room.members.values()) m.tell({ room: name, went: end.id });
  }

  /** A connection closed: out of every room it was in. */
  gone(end) {
    if (!this.ends.delete(end)) return;
    for (const name of [...end.rooms]) this.leave(end, name);
  }

  /** Who is in a room now. */
  members(name) {
    return [...(this.rooms.get(name)?.members.keys() ?? [])];
  }
}

/** Waits until [f] is true (polled), or fails after [ms]. */
export async function until(f, ms = 3000, what = 'condition') {
  const end = Date.now() + ms;
  while (!(await f())) {
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 5));
  }
}

/** Timers by hand: setTimer/clearTimer/setInterval/clearInterval, moved on with advance(ms). */
export function manualTimers() {
  let now = 0;
  let next = 1;
  const timers = new Map(); // id -> { at, f, every }
  const t = {
    now: () => now,
    setTimer: (f, ms) => { const id = next++; timers.set(id, { at: now + ms, f, every: 0 }); return id; },
    clearTimer: (id) => { timers.delete(id); },
    setInterval: (f, ms) => { const id = next++; timers.set(id, { at: now + ms, f, every: ms }); return id; },
    clearInterval: (id) => { timers.delete(id); },
    advance(ms) {
      const end = now + ms;
      for (;;) {
        let first = null;
        for (const [id, x] of timers) if (x.at <= end && (!first || x.at < first[1].at)) first = [id, x];
        if (!first) break;
        const [id, x] = first;
        now = x.at;
        if (x.every) x.at += x.every;
        else timers.delete(id);
        x.f();
      }
      now = end;
    },
    pending: () => timers.size,
  };
  return t;
}
