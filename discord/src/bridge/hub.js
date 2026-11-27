// The bridge's way onto Uplink's relay hub: its key pair (kept, so its hub id stays the same across restarts), the
// signed sign-in, rooms joined and left, and sealed room packets. As voice.js's identity() and connectHub(), with
// node:crypto for the key and Node 22's own WebSocket; it reconnects by itself and joins its rooms again.
//
// The hub (relay/lib/hub.dart): it says {hello: <hex>}; we answer {id, key: base64(33-byte key), sig: base64(r||s of
// ECDSA P-256 over "ghost-hub v1 " || hello)}; it says {ok: true}. Then {join: room, token} -> {room, ok, members},
// {room, came}, {room, went}; {leave: room}; binary [2][room][sealed] out, [2][room][from][sealed] in.
import { createPrivateKey, createPublicKey, generateKeyPairSync, sign as signWith } from 'node:crypto';
import { hex, parseRoomFrame, roomFrame, sha256 } from './protocol.js';

/** What is signed before the hub's hello, so the signature is of no use anywhere else. */
const GREETING = Buffer.from('ghost-hub v1 ', 'utf8');

/** A key pair from its PKCS#8 PEM (or a new one), with the hub id and the compressed public key the hub wants. */
export function makeIdentity(pem = null) {
  const privateKey = pem ? createPrivateKey(pem) : generateKeyPairSync('ec', { namedCurve: 'prime256v1' }).privateKey;
  const jwk = createPublicKey(privateKey).export({ format: 'jwk' });
  const x = Buffer.from(jwk.x, 'base64url');
  const y = Buffer.from(jwk.y, 'base64url');
  // The compressed point: 02 or 03 by whether y is even or odd, then x. The hub id is the first 16 bytes of its hash.
  const pub = Buffer.concat([Buffer.from([y[y.length - 1] & 1 ? 3 : 2]), x]);
  return {
    id: hex(sha256(pub).subarray(0, 16)),
    pub,
    pem: privateKey.export({ format: 'pem', type: 'pkcs8' }).toString(),
    sign: (bytes) => signWith('sha256', bytes, { key: privateKey, dsaEncoding: 'ieee-p1363' }),
  };
}

/**
 * One connection to the hub, kept up. connect(url) makes a WebSocket-like object (default: Node's WebSocket);
 * tests pass a fake. Listeners: onEvent({room, ok, members, came, went, err}), onPacket({room, from, sealed}),
 * onState(up: boolean).
 */
export class Hub {
  constructor({ url, me, connect = (u) => new WebSocket(u), log = () => {}, retryMs = 2000, setTimer = setTimeout, clearTimer = clearTimeout }) {
    this.url = url;
    this.me = me;
    this.connect = connect;
    this.log = log;
    this.retryMs = retryMs;
    this.setTimer = setTimer;
    this.clearTimer = clearTimer;
    // up: signed in (not merely connected). tries: failed connections in a row, for the wait before the next.
    this.up = false;
    this.rooms = new Map(); // room -> token: joined, and joined again on every sign-in
    this.joining = new Map(); // room -> [{ done, fail }]
    this.listeners = { event: new Set(), packet: new Set(), state: new Set() };
    this.tries = 0;
    this.stopped = true;
    this.ws = null;
  }

  /** Listens to 'event', 'packet' or 'state'; the function returned stops listening. */
  on(kind, f) {
    this.listeners[kind].add(f);
    return () => this.listeners[kind].delete(f);
  }

  /** Tells every listener of a kind; one that throws is logged and the rest still hear. */
  emit(kind, value) {
    for (const f of this.listeners[kind]) {
      try {
        f(value);
      } catch (e) {
        this.log(`hub listener failed: ${e?.message ?? e}`);
      }
    }
  }

  start() {
    if (!this.stopped) return;
    this.stopped = false;
    this.open();
  }

  /** Closes the connection for good: no reconnecting until start() again. Joins still waiting fail here, since the
   * socket's own close is no longer listened to. */
  stop() {
    this.stopped = true;
    this.clearTimer(this.again);
    try {
      this.ws?.close();
    } catch {}
    this.ws = null;
    this.setUp(false);
    for (const [, waiting] of this.joining) for (const w of waiting) w.fail(new Error('hub stopped'));
    this.joining.clear();
  }

  setUp(up) {
    if (this.up === up) return;
    this.up = up;
    this.emit('state', up);
  }

  /** One connection attempt. The hub speaks first (its hello), so nothing is sent here. */
  open() {
    let ws;
    try {
      ws = this.connect(this.url);
    } catch (e) {
      this.lost(ws, `could not connect (${e?.message ?? e})`);
      return;
    }
    this.ws = ws;
    ws.binaryType = 'arraybuffer';
    ws.onmessage = (e) => this.said(ws, e.data);
    ws.onclose = () => this.lost(ws, 'closed');
    ws.onerror = () => {};
  }

  /** The connection gone (or never made): joins still waiting fail, and another attempt is set for later, after
   * retryMs, doubling to eight times it over four failures and then fifteen times it. */
  lost(ws, why) {
    // A socket already replaced by a newer one: its close is of no interest.
    if (ws && this.ws !== ws) return;
    this.ws = null;
    const was = this.up;
    this.setUp(false);
    for (const [, waiting] of this.joining) for (const w of waiting) w.fail(new Error('hub connection lost'));
    this.joining.clear();
    if (this.stopped) return;
    if (was || this.tries === 0) this.log(`hub: ${why}; connecting again`);
    const wait = this.retryMs * (this.tries < 4 ? 1 << this.tries : 15);
    this.tries++;
    this.again = this.setTimer(() => this.open(), wait);
  }

  /** Text or bytes to the hub; false when the socket is not open (nothing is queued). */
  send(message) {
    if (this.ws && this.ws.readyState === 1) {
      this.ws.send(message);
      return true;
    }
    return false;
  }

  /** A JSON message to the hub. */
  say(m) {
    return this.send(JSON.stringify(m));
  }

  /** Something from the hub: a binary room packet, or JSON (the sign-in's steps, then answers and news of rooms). */
  said(ws, data) {
    if (this.ws !== ws) return;
    if (typeof data !== 'string') {
      const p = parseRoomFrame(data instanceof ArrayBuffer ? new Uint8Array(data) : data);
      if (p) this.emit('packet', p);
      return;
    }
    let m;
    try {
      m = JSON.parse(data);
    } catch {
      return;
    }
    if (typeof m.hello === 'string' && !this.up) {
      const sig = this.me.sign(Buffer.concat([GREETING, Buffer.from(m.hello, 'hex')]));
      this.say({ id: this.me.id, key: this.me.pub.toString('base64'), sig: Buffer.from(sig).toString('base64') });
    } else if ('ok' in m && typeof m.room !== 'string' && !this.up) {
      if (!m.ok) {
        this.log('hub: refused the bridge\'s sign-in');
        try {
          ws.close();
        } catch {}
        return;
      }
      // Signed in: every room joined before is joined again.
      this.tries = 0;
      this.setUp(true);
      for (const [room, token] of this.rooms) this.say({ join: room, token });
    } else if (typeof m.room === 'string') {
      if ('ok' in m) {
        const waiting = this.joining.get(m.room) ?? [];
        this.joining.delete(m.room);
        if (m.ok) for (const w of waiting) w.done(m.members ?? []);
        else {
          this.rooms.delete(m.room);
          for (const w of waiting) w.fail(new Error(m.err ?? 'refused'));
        }
      }
      this.emit('event', m);
    }
  }

  /** Joins [room] (and again after every reconnect); the members already in it. */
  join(room, token) {
    this.rooms.set(room, token);
    return new Promise((done, fail) => {
      const list = this.joining.get(room) ?? [];
      list.push({ done, fail });
      this.joining.set(room, list);
      if (this.up) this.say({ join: room, token });
    });
  }

  /** Leaves [room], and does not join it again after a reconnect. A join of it still waiting fails. */
  leave(room) {
    this.rooms.delete(room);
    for (const w of this.joining.get(room) ?? []) w.fail(new Error('left the room'));
    this.joining.delete(room);
    if (this.up) this.say({ leave: room });
  }

  /** Sealed bytes to everyone else in [room]. */
  sendRoom(room, sealed) {
    return this.send(roomFrame(room, sealed));
  }
}
