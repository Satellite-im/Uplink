// An Uplink hangout in a browser (Matt, 2026-11-14: "Make the voice hangouts possible to share via a link so
// people can join to talk anonymously or sign up through the browser similar to a zoom meeting").
//
// The app's own protocol, as lib/voice/voice.dart, lib/voice/rtc.dart, lib/net/hub_carrier.dart and lib/net/crypto.dart
// have it (tool/voicebench/bench.html measured the same against the relay): a key pair, the hub's greeting signed with
// it, the room's name, token and key made from the channel's seed, everything said in the room sealed with that key,
// the newcomer offering, Opus at 510 kb/s stereo and the picture sized by how many are in the call.
//
// The seed comes from the link's fragment (after the #), which a browser never sends to any server: the relay sees
// that someone is in some room, never what is said or which channel it is.

const enc = new TextEncoder(), dec = new TextDecoder();
export const hex = (b) => [...new Uint8Array(b)].map((x) => x.toString(16).padStart(2, '0')).join('');
export const unhex = (h) => new Uint8Array((h.match(/../g) ?? []).map((x) => parseInt(x, 16)));
const b64 = (b) => btoa(String.fromCharCode(...new Uint8Array(b)));
const sha256 = async (b) => new Uint8Array(await crypto.subtle.digest('SHA-256', b));
async function hmac(key, data) {
  const k = await crypto.subtle.importKey('raw', key, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return new Uint8Array(await crypto.subtle.sign('HMAC', k, data));
}
const derive = (key, label) => hmac(key, new Uint8Array([...enc.encode('ghost-net ' + label), 1]));
const AAD = enc.encode('ghost-net-v1');
async function seal(key, clear) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv, additionalData: AAD, tagLength: 128 }, key, clear));
  return new Uint8Array([...iv, ...ct]);
}
async function open(key, sealed) {
  try { return new Uint8Array(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: sealed.slice(0, 12), additionalData: AAD, tagLength: 128 }, key, sealed.slice(12))); } catch (_) { return null; }
}

const readName = (b64, fallback) => {
  try { if (b64) return dec.decode(Uint8Array.from(atob(b64.replace(/-/g, '+').replace(/_/g, '/')), (c) => c.charCodeAt(0))) || fallback; } catch (_) {}
  return fallback;
};

/**
 * The link's fragment: the channel's seed, its name, its owner's key (lib/voice/roles.dart), and its kind (lib/voice/voice.dart
 * SpaceKind: 'voice', or a texting, Files or open space's 'text', 'files' or 'open', which the link ends with). Null where it
 * is not one.
 */
export function readLink(fragment) {
  const { rest, relay } = splitRelay(fragment);
  const m = /^#?([0-9a-f]{64})(?:\.([A-Za-z0-9_-]*))?(?:\.(0[23][0-9a-f]{64}))?(?:\.(voice|text|files|open))?$/.exec(rest);
  if (!m) return null;
  return { seed: m[1], name: readName(m[2], 'Space'), owner: m[3] ?? '', kind: m[4] ?? 'voice', relay };
}

/**
 * The relay a link names after an `@` at its end (lib/invites/link_relay.dart; GMFB-25): a space or a circle made on a
 * relay other than Uplink's says which, `…@relay.example.com`. The fragment without it, and the relay's host
 * (lower case, with its port where it has one), or '' where it names none. What follows the `@` is taken only where
 * it could be a host, as the app takes it (lib/net/home_record.dart goodRelayHost).
 */
export function splitRelay(fragment) {
  const f = fragment ?? '';
  const at = f.lastIndexOf('@');
  if (at < 0) return { rest: f, relay: '' };
  const host = f.slice(at + 1).toLowerCase();
  const ok = host.length <= 120 && /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+(:[0-9]{1,5})?$/.test(host);
  return ok ? { rest: f.slice(0, at), relay: host } : { rest: f, relay: '' };
}

/**
 * A circle's link (lib/circles/circle.dart Circle.link): `c.` then its seed, its name and its owner's key. A circle opens in
 * the app, where its list of spaces is; this page says what it is and how to get there. Null where it is not one.
 */
export function readCircleLink(fragment) {
  const { rest, relay } = splitRelay(fragment);
  const m = /^#?c\.([0-9a-f]{64})(?:\.([A-Za-z0-9_-]*))?(?:\.(0[23][0-9a-f]{64}))?$/.exec(rest);
  if (!m) return null;
  return { seed: m[1], name: readName(m[2], 'Circle'), owner: m[3] ?? '', relay };
}

// lib/voice/voice.dart highestOpus and videoFor.
export function highestOpus(sdp) {
  const lines = sdp.split('\r\n');
  const opus = /^a=rtpmap:(\d+) opus\/48000/i;
  const pts = new Set(lines.filter((l) => opus.test(l)).map((l) => l.match(opus)[1]));
  if (!pts.size) return sdp;
  const want = { minptime: '10', useinbandfec: '1', stereo: '1', 'sprop-stereo': '1', maxaveragebitrate: '510000', maxplaybackrate: '48000', cbr: '1', usedtx: '0' };
  const out = [];
  for (const l of lines) {
    const f = l.match(/^a=fmtp:(\d+) (.*)$/);
    if (f && pts.has(f[1])) {
      const p = {};
      for (const kv of f[2].split(';')) { const i = kv.indexOf('='); if (i > 0) p[kv.slice(0, i).trim()] = kv.slice(i + 1).trim(); }
      Object.assign(p, want);
      out.push('a=fmtp:' + f[1] + ' ' + Object.entries(p).map(([k, v]) => k + '=' + v).join(';'));
      continue;
    }
    out.push(l);
    const r = l.match(opus);
    if (r && !lines.some((x) => x.startsWith('a=fmtp:' + r[1] + ' '))) out.push('a=fmtp:' + r[1] + ' ' + Object.entries(want).map(([k, v]) => k + '=' + v).join(';'));
  }
  return out.join('\r\n');
}
export const videoFor = (others) => (others <= 1 ? { scale: 1, bitrate: 12000000 } : others === 2 ? { scale: 1.5, bitrate: 4000000 } : others <= 4 ? { scale: 2, bitrate: 2000000 } : { scale: 3, bitrate: 1000000 });

// --- who this browser is ------------------------------------------------------------------------------------------

/** This browser's key pair: kept (the private half unreadable even to this page) where [keep], else made for now. */
export async function identity(keep) {
  const db = keep ? await new Promise((done) => {
    const r = indexedDB.open('ghost-voice', 1);
    r.onupgradeneeded = () => r.result.createObjectStore('keys');
    r.onsuccess = () => done(r.result);
    r.onerror = () => done(null);
  }) : null;
  const get = (k) => new Promise((done) => { if (!db) return done(null); const q = db.transaction('keys').objectStore('keys').get(k); q.onsuccess = () => done(q.result ?? null); q.onerror = () => done(null); });
  const put = (k, v) => new Promise((done) => { if (!db) return done(); const t = db.transaction('keys', 'readwrite'); t.objectStore('keys').put(v, k); t.oncomplete = done; t.onerror = done; });
  let pair = await get('pair');
  if (!pair) {
    pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']);
    await put('pair', pair);
  }
  const raw = new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey));
  const pub = new Uint8Array([raw[64] & 1 ? 3 : 2, ...raw.slice(1, 33)]);
  const id = hex((await sha256(pub)).slice(0, 16));
  return { id, pub, sign: async (bytes) => new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, pair.privateKey, bytes)) };
}

// --- the hub ------------------------------------------------------------------------------------------------------

/** A connection to the relay's hub, signed in as [me]. */
export async function connectHub(url, me) {
  const ws = new WebSocket(url);
  ws.binaryType = 'arraybuffer';
  const hub = { ws, me, json: new Set(), bin: new Set(), waiting: new Map() };
  hub.say = (m) => ws.readyState === 1 && ws.send(JSON.stringify(m));
  hub.dir = (m, answer) => new Promise((done, fail) => {
    hub.waiting.set(answer, { done, fail });
    hub.say(m);
    setTimeout(() => { if (hub.waiting.delete(answer)) fail(new Error('The relay server did not answer.')); }, 15000);
  });
  await new Promise((done, fail) => {
    ws.onerror = () => fail(new Error('The relay server can’t be reached.'));
    ws.onclose = () => fail(new Error('The relay server closed the connection.'));
    ws.onmessage = async (e) => {
      if (typeof e.data !== 'string') { for (const f of hub.bin) f(new Uint8Array(e.data)); return; }
      const m = JSON.parse(e.data);
      if (m.hello) {
        const sig = await me.sign(new Uint8Array([...enc.encode('ghost-hub v1 '), ...unhex(m.hello)]));
        hub.say({ id: me.id, key: b64(me.pub), sig: b64(sig) });
      } else if ('ok' in m && !m.room && !hub.up) {
        if (!m.ok) return fail(new Error('The relay server refused this browser.'));
        hub.up = true;
        done();
      } else if (m.dir) {
        const w = hub.waiting.get(m.dir) ?? (m.dir === 'err' ? hub.waiting.get(m.about) : null);
        if (w) { hub.waiting.delete(m.dir === 'err' ? m.about : m.dir); m.dir === 'err' ? w.fail(new Error(m.err)) : w.done(m); }
      } else {
        for (const f of hub.json) f(m);
      }
    };
  });
  ws.onclose = () => { hub.up = false; for (const f of hub.json) f({ closed: true }); };
  return hub;
}

// --- a hangout ----------------------------------------------------------------------------------------------------

/** One channel: who is in it before joining, and being in it. [onChange] is called whenever anything shown changes. */
export class Hangout {
  constructor(hub, seed, onChange) {
    this.hub = hub;
    this.seedHex = seed;
    this.onChange = onChange;
    this.members = new Map(); // id -> { name, muted, video, guest, stream }
    this.offered = new Set(); // those this browser offered to
    this.retried = new Set(); // those it started over with through the relay alone
    this.relay = null;
    this.peers = new Map();
    this.early = new Map();
    this.here = [];
    this.joined = false;
    this.muted = false;
    this.video = false;
  }

  async prepare() {
    const s = unhex(this.seedHex);
    this.room = hex((await derive(s, 'voice room')).slice(0, 16));
    this.token = hex(await derive(s, 'voice token'));
    this.key = await crypto.subtle.importKey('raw', await derive(s, 'voice key'), 'AES-GCM', false, ['encrypt', 'decrypt']);
    this.hub.json.add((m) => this.event(m));
    this.hub.bin.add((d) => this.packet(d));
    // Who is in it, without joining.
    this.hub.say({ look: this.room, token: this.token });
  }

  change() { this.onChange?.(); }

  async join({ name, guest, username, audio = true, video = false }) {
    this.name = name;
    this.guest = guest;
    this.username = username || null;
    this.mic = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true, noiseSuppression: false, autoGainControl: false, channelCount: 2, sampleRate: 48000 }, video: false });
    if (!audio) this.setMuted(true);
    if (video) await this.setVideo(true);
    this.hub.say({ join: this.room, token: this.token });
  }

  event(m) {
    if (m.closed) { this.lost = true; return this.change(); }
    if (m.room !== this.room) return;
    if (Array.isArray(m.look)) { this.here = m.look; return this.change(); }
    if ('ok' in m) {
      if (!m.ok) { this.refused = m.err ?? 'refused'; return this.change(); }
      // The relay's TURN server for calls (relay/lib/turn.dart): where two can't reach each other directly.
      if (m.ice && typeof m.ice === 'object') this.relay = m.ice;
      this.joined = true;
      for (const id of m.members) this.members.set(id, this.members.get(id) ?? { name: '' });
      this.sayMe();
      for (const id of m.members) this.offer(id);
      setTimeout(() => this.retune(), 1500);
    } else if (m.came) {
      this.members.set(m.came, this.members.get(m.came) ?? { name: '' });
      this.sayMe();
      setTimeout(() => this.retune(), 1500);
    } else if (m.went) {
      this.members.delete(m.went);
      this.offered.delete(m.went);
      this.retried.delete(m.went);
      this.peers.get(m.went)?.close();
      this.peers.delete(m.went);
      this.retune();
    }
    this.change();
  }

  sayMe() { this.say({ t: 'me', n: this.name, m: this.muted, v: this.video, g: this.guest, ...(this.username ? { u: this.username } : {}) }); }

  async say(what) {
    if (!this.joined && what.t !== 'me') return;
    const sealed = await seal(this.key, enc.encode(JSON.stringify(what)));
    if (this.hub.ws.readyState === 1) this.hub.ws.send(new Uint8Array([2, ...unhex(this.room), ...sealed]));
  }

  async packet(d) {
    if (d[0] !== 2 || d.length < 34 || hex(d.slice(1, 17)) !== this.room) return;
    const from = hex(d.slice(17, 33));
    const clear = await open(this.key, d.slice(33));
    if (!clear) return;
    let m;
    try { m = JSON.parse(dec.decode(clear)); } catch (_) { return; }
    if (m.to && m.to !== this.hub.me.id) return;
    // Someone the hangout banned is not answered (lib/voice/hangout.dart).
    if (this.refuse?.(from)) { this.members.delete(from); this.peers.get(from)?.close(); this.peers.delete(from); return this.change(); }
    if (m.t === 'me') {
      const had = this.members.get(from) ?? {};
      this.members.set(from, { ...had, name: String(m.n ?? ''), muted: !!m.m, video: !!m.v, guest: !!m.g });
      this.change();
    } else if (m.t === 'offer') {
      // Started over: through the relay alone after no way through was found (`r`), or a connection the app is
      // mending (`a`: lib/voice/voice.dart _failed, _mendAll). Either way the one held here goes and theirs is answered.
      const relay = m.r === 1;
      const again = relay || m.a === 1;
      if (again) { this.peers.get(from)?.close(); this.peers.delete(from); this.early.delete(from); }
      else this.offered.delete(from);
      const pc = this.pc(from, relay);
      await pc.setRemoteDescription({ type: 'offer', sdp: m.sdp });
      await this.flush(from);
      for (const t of pc.getTransceivers()) {
        const kind = t.receiver.track?.kind;
        if (kind === 'audio') await t.sender.replaceTrack(this.mic.getAudioTracks()[0]);
        if (kind === 'video') await t.sender.replaceTrack(this.cam?.getVideoTracks()[0] ?? null);
        t.direction = 'sendrecv';
      }
      const answer = await pc.createAnswer();
      const sdp = highestOpus(answer.sdp);
      await pc.setLocalDescription({ type: 'answer', sdp });
      await this.highest(pc);
      this.say({ t: 'answer', to: from, sdp });
      this.sayMe();
    } else if (m.t === 'answer') {
      const pc = this.peers.get(from);
      if (!pc) return;
      await pc.setRemoteDescription({ type: 'answer', sdp: m.sdp });
      await this.flush(from);
    } else if (m.t === 'ice' && m.c) {
      const pc = this.pc(from);
      if (pc.remoteDescription) await pc.addIceCandidate(m.c).catch(() => {});
      else (this.early.get(from) ?? this.early.set(from, []).get(from)).push(m.c);
    }
  }

  async flush(from) {
    for (const c of this.early.get(from) ?? []) await this.peers.get(from).addIceCandidate(c).catch(() => {});
    this.early.delete(from);
  }

  // Every path at once (direct, and the relay where the hub handed one out), the best that works taken; [relayOnly]: the
  // relay alone, the second try after none was found (Matt, 2026-11-21: "if p2p fails please connect over voice through
  // the relay").
  pc(id, relayOnly = false) {
    let pc = this.peers.get(id);
    if (pc) return pc;
    const iceServers = [{ urls: ['stun:stun.l.google.com:19302', 'stun:stun1.l.google.com:19302'] }, ...(this.relay ? [this.relay] : [])];
    pc = new RTCPeerConnection({ iceServers, ...(relayOnly ? { iceTransportPolicy: 'relay' } : {}) });
    pc.onicecandidate = (e) => { if (e.candidate) this.say({ t: 'ice', to: id, c: { candidate: e.candidate.candidate, sdpMid: e.candidate.sdpMid, sdpMLineIndex: e.candidate.sdpMLineIndex } }); };
    pc.ontrack = (e) => {
      const m = this.members.get(id) ?? { name: '' };
      const stream = m.stream ?? e.streams[0] ?? new MediaStream();
      if (!stream.getTracks().includes(e.track)) stream.addTrack(e.track);
      this.members.set(id, { ...m, stream });
      this.change();
    };
    pc.onconnectionstatechange = () => {
      // No way through: the side that offered starts over once, through the relay alone.
      if (pc.connectionState === 'failed' && this.peers.get(id) === pc && this.offered.has(id) && !this.retried.has(id) && this.relay && this.members.has(id)) {
        this.retried.add(id);
        pc.close();
        this.peers.delete(id);
        this.early.delete(id);
        this.offer(id, true);
      }
      this.change();
    };
    this.peers.set(id, pc);
    return pc;
  }

  async offer(id, relayOnly = false) {
    this.offered.add(id);
    const pc = this.pc(id, relayOnly);
    const vf = videoFor(this.members.size);
    pc.addTransceiver(this.mic.getAudioTracks()[0], { direction: 'sendrecv', streams: [this.mic] });
    const v = pc.addTransceiver('video', { direction: 'sendrecv', sendEncodings: [{ maxBitrate: vf.bitrate, maxFramerate: 30, scaleResolutionDownBy: vf.scale }] });
    if (this.cam) await v.sender.replaceTrack(this.cam.getVideoTracks()[0]);
    const offer = await pc.createOffer();
    const sdp = highestOpus(offer.sdp);
    await pc.setLocalDescription({ type: 'offer', sdp });
    await this.highest(pc);
    this.say({ t: 'offer', to: id, sdp, ...(relayOnly ? { r: 1 } : {}) });
  }

  async highest(pc) {
    const vf = videoFor(this.members.size);
    for (const s of pc.getSenders()) {
      const p = s.getParameters();
      if (!p.encodings?.length) continue;
      for (const e of p.encodings) {
        e.maxBitrate = s.track?.kind === 'audio' ? 510000 : vf.bitrate;
        if (s.track?.kind === 'video') e.scaleResolutionDownBy = vf.scale;
      }
      if (s.track?.kind === 'video') p.degradationPreference = 'balanced';
      try { await s.setParameters(p); } catch (_) {}
    }
  }

  retune() { for (const pc of this.peers.values()) this.highest(pc); }

  setMuted(on) {
    this.muted = on;
    for (const t of this.mic?.getAudioTracks() ?? []) t.enabled = !on;
    this.sayMe();
    this.change();
  }

  async setVideo(on) {
    if (on && !this.cam) {
      this.cam = await navigator.mediaDevices.getUserMedia({ video: { width: 1920, height: 1080, frameRate: 30, facingMode: 'user' } });
    } else if (!on && this.cam) {
      for (const t of this.cam.getTracks()) t.stop();
      this.cam = null;
    }
    this.video = !!this.cam;
    for (const pc of this.peers.values()) {
      for (const t of pc.getTransceivers()) {
        if (t.receiver.track?.kind === 'video') await t.sender.replaceTrack(this.cam?.getVideoTracks()[0] ?? null);
      }
      await this.highest(pc);
    }
    this.sayMe();
    this.change();
  }

  leave() {
    this.hub.say({ leave: this.room });
    for (const pc of this.peers.values()) pc.close();
    this.peers.clear();
    this.offered.clear();
    this.retried.clear();
    for (const s of [this.mic, this.cam]) for (const t of s?.getTracks() ?? []) t.stop();
    this.mic = this.cam = null;
    for (const m of this.members.values()) delete m.stream;
    this.members.clear();
    this.joined = false;
    this.change();
  }
}

// --- roles and the chat (lib/voice/roles.dart, lib/voice/hangout.dart) ------------------------------------------
//
// Matt, 2026-11-15: "Implement a permissions system similar to discord for hangouts and add a chat to hangouts so the
// whole group can send messages to the hangout as well as voice and video, make default roles such as admin,
// moderator, member". The same rules as the app: a roster believed only when the owner (whose key is in the link) or
// an admin the owner made signed it, and each device doing what it says.

// In Perm.values' order (lib/voice/roles.dart), a Files space's two at the end: a roster is signed with its roles'
// permissions in this order, so a browser that left them out rebuilt different bytes and refused every Files space's.
export const PERMS = ['speak', 'video', 'chat', 'invite', 'muteOthers', 'removeMembers', 'ban', 'manageMessages', 'uploadFiles', 'manageFiles'];
// What a voice or texting space's admin may do: every permission but a Files space's own.
const SPACE_PERMS = PERMS.filter((p) => p !== 'uploadFiles' && p !== 'manageFiles');
const DEFAULT_ROLES = [
  { id: 'admin', n: 'Admin', p: SPACE_PERMS, r: 30 },
  { id: 'moderator', n: 'Moderator', p: ['speak', 'video', 'chat', 'invite', 'muteOthers', 'removeMembers', 'manageMessages'], r: 20 },
  { id: 'member', n: 'Member', p: ['speak', 'video', 'chat', 'invite'], r: 10 },
];
const idOf = async (pub) => hex((await sha256(pub)).slice(0, 16));

// P-256's numbers, to open a key written as 33 bytes (02 or 03, then x) into the 65 WebCrypto takes.
const P = 0xffffffff00000001000000000000000000000000ffffffffffffffffffffffffn;
const B = 0x5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604bn;
const modpow = (b, e, m) => { let r = 1n; b %= m; while (e > 0n) { if (e & 1n) r = (r * b) % m; b = (b * b) % m; e >>= 1n; } return r; };
const big = (bytes) => BigInt('0x' + (hex(bytes) || '0'));
const bytes32 = (n) => unhex(n.toString(16).padStart(64, '0'));
async function verify(pub33, message, sig) {
  try {
    if (pub33.length !== 33 || sig.length !== 64) return false;
    const x = big(pub33.slice(1));
    let y = modpow((x * x * x - 3n * x + B) % P, (P + 1n) / 4n, P);
    if ((y & 1n) !== BigInt(pub33[0] & 1)) y = P - y;
    const key = await crypto.subtle.importKey('raw', new Uint8Array([4, ...bytes32(x), ...bytes32(y)]), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
    return await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, key, sig, message);
  } catch (_) { return false; }
}

/** A roster as the app keeps it, with what it says worked out (Roster in lib/voice/roles.dart). */
export class Roster {
  constructor(j, owner, ownerId) {
    this.j = j ?? { o: owner, v: 0, roles: [], a: {}, g: {}, b: [], m: [], n: 'member' };
    this.owner = owner;
    this.ownerId = ownerId;
    this.granted = new Set();
  }
  get version() { return this.j.v ?? 0; }
  get roles() { return (this.j.roles?.length ? this.j.roles : DEFAULT_ROLES).slice().sort((a, b) => b.r - a.r); }
  role(id) { return this.roles.find((r) => r.id === id); }
  isOwner(id) { return !!this.owner && id === this.ownerId; }
  roleOf(id) {
    if (this.isOwner(id)) return this.role('admin');
    let named = this.j.a?.[id] ?? this.j.n ?? 'member';
    if (named === 'admin' && !this.granted.has(id)) named = this.j.n === 'admin' ? 'member' : (this.j.n ?? 'member');
    return this.role(named) ?? this.role('member') ?? DEFAULT_ROLES[2];
  }
  can(id, perm) {
    if (this.isOwner(id)) return true;
    if ((this.j.b ?? []).includes(id)) return false;
    if (perm === 'speak' && (this.j.m ?? []).includes(id)) return false;
    if (!this.owner) return DEFAULT_ROLES[2].p.includes(perm);
    return this.roleOf(id).p.includes(perm);
  }
  banned(id) { return (this.j.b ?? []).includes(id); }
  outranks(a, b) { if (a === b || this.isOwner(b)) return false; if (this.isOwner(a)) return true; return this.roleOf(a).r > this.roleOf(b).r; }

  /** The admins whose grant from the owner checks out. */
  async checkGrants() {
    this.granted = new Set();
    for (const [id, g] of Object.entries(this.j.g ?? {})) {
      if (await verify(unhex(this.owner), enc.encode(`ghost-hangout admin|${this.owner}|${id}`), unhex(g))) this.granted.add(id);
    }
  }

  /** Whether to believe it: the app's Roster.trustedFor. The bytes signed are the app's, field for field. */
  async trusted() {
    const j = this.j;
    if (!this.owner || j.o !== this.owner || !j.by || !j.k || !j.s) return false;
    const k = unhex(j.k);
    if ((await idOf(k)) !== j.by) return false;
    const sorted = (o) => Object.fromEntries(Object.entries(o ?? {}).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)));
    const body = { o: j.o, v: j.v, roles: (j.roles ?? []).map((r) => ({ id: r.id, n: r.n, p: [...PERMS.filter((p) => r.p.includes(p)), ...r.p.filter((p) => !PERMS.includes(p))], r: r.r, ...(typeof r.c === 'string' ? { c: r.c } : {}) })), a: sorted(j.a), g: sorted(j.g), b: [...(j.b ?? [])].sort(), m: [...(j.m ?? [])].sort(), n: j.n, by: j.by, k: j.k };
    if (!(await verify(k, enc.encode('ghost-hangout roster|' + JSON.stringify(body)), unhex(j.s)))) return false;
    await this.checkGrants();
    if (!(this.isOwner(j.by) || this.roleOf(j.by).id === 'admin')) return false;
    for (const [id, r] of Object.entries(j.a ?? {})) if (r === 'admin' && !this.granted.has(id)) return false;
    if ((j.b ?? []).includes(this.ownerId) || (j.m ?? []).includes(this.ownerId)) return false;
    return true;
  }
}

/** A hangout's chat room: its messages, who is here, and its roster, as lib/voice/hangout.dart has them. */
export class Chat {
  constructor(hub, seed, owner, onChange) {
    this.hub = hub;
    this.seedHex = seed;
    this.owner = owner;
    this.onChange = onChange;
    this.messages = [];
    this.present = new Map();
    this.heldMutes = new Set();
    this.opened = false;
  }

  async prepare() {
    const s = unhex(this.seedHex);
    this.room = hex((await derive(s, 'hangout room')).slice(0, 16));
    this.token = hex(await derive(s, 'hangout token'));
    this.key = await crypto.subtle.importKey('raw', await derive(s, 'voice key'), 'AES-GCM', false, ['encrypt', 'decrypt']);
    this.ownerId = this.owner ? await idOf(unhex(this.owner)) : '';
    this.roster = new Roster(null, this.owner, this.ownerId);
    try {
      const kept = JSON.parse(localStorage.getItem('ghost-hangout-' + this.room) ?? 'null');
      if (kept) {
        const r = new Roster(kept.r, this.owner, this.ownerId);
        if (kept.r && (await r.trusted())) this.roster = r;
        this.messages = kept.m ?? [];
      }
    } catch (_) {}
    this.hub.json.add((m) => this.event(m));
    this.hub.bin.add((d) => this.packet(d));
  }

  get me() { return this.hub.me.id; }
  can(perm) { return this.roster.can(this.me, perm); }
  heard(id) { return this.roster.can(id, 'speak') && !this.heldMutes.has(id); }
  change() { this.onChange?.(); }
  keep() { try { localStorage.setItem('ghost-hangout-' + this.room, JSON.stringify({ r: this.roster.j.s ? this.roster.j : null, m: this.messages.slice(-300) })); } catch (_) {} }

  open({ name, guest, username }) {
    this.name = name;
    this.guest = guest;
    this.username = username;
    if (this.roster.banned(this.me)) this.putOut = 'You were banned from this space.';
    this.hub.say({ join: this.room, token: this.token });
  }

  close() { if (this.opened) this.hub.say({ leave: this.room }); this.opened = false; this.present.clear(); }

  hi() { this.say({ t: 'hi', n: this.name, a: true, g: !!this.guest, ...(this.username ? { u: this.username } : {}) }); }

  event(m) {
    if (m.room !== this.room) return;
    if ('ok' in m) {
      if (!m.ok) return;
      this.opened = true;
      for (const id of m.members ?? []) this.present.set(id, this.present.get(id) ?? { name: '' });
      this.hi();
      this.say({ t: 'sync?', since: this.messages.at(-1)?.at ?? 0, v: this.roster.version });
    } else if (m.came) {
      this.present.set(m.came, { name: '' });
      this.hi();
    } else if (m.went) {
      this.present.delete(m.went);
      this.heldMutes.delete(m.went);
    }
    this.change();
  }

  async say(what) {
    if (!this.opened) return;
    const sealed = await seal(this.key, enc.encode(JSON.stringify(what)));
    if (this.hub.ws.readyState === 1) this.hub.ws.send(new Uint8Array([2, ...unhex(this.room), ...sealed]));
  }

  send(text) {
    const x = text.trim();
    if (!x || !this.can('chat') || this.putOut) return false;
    const m = { id: hex(crypto.getRandomValues(new Uint8Array(8))), x: x.slice(0, 4000), at: Date.now(), n: this.name, f: this.me };
    this.add([m]);
    this.say({ t: 'msg', id: m.id, x: m.x, at: m.at, n: m.n });
    return true;
  }

  canDelete(m) { return m.f === this.me || this.roster.isOwner(this.me) || (this.can('manageMessages') && this.roster.outranks(this.me, m.f)); }
  remove(m) { if (!this.canDelete(m)) return; this.drop(m.id); this.say({ t: 'del', id: m.id }); }

  add(list) {
    const have = new Set(this.messages.map((m) => m.id));
    const more = list.filter((m) => m && typeof m.id === 'string' && typeof m.x === 'string' && typeof m.at === 'number' && !have.has(m.id) && have.add(m.id));
    if (!more.length) return;
    this.messages = [...this.messages, ...more].sort((a, b) => a.at - b.at).slice(-300);
    this.keep();
    this.change();
  }

  drop(id) { const n = this.messages.length; this.messages = this.messages.filter((m) => m.id !== id); if (this.messages.length !== n) { this.keep(); this.change(); } }

  answers(asker) { return [this.me, ...[...this.present.keys()].filter((id) => id !== asker)].sort()[0] === this.me; }

  async packet(d) {
    if (d[0] !== 2 || d.length < 34 || hex(d.slice(1, 17)) !== this.room) return;
    const from = hex(d.slice(17, 33));
    const clear = await open(this.key, d.slice(33));
    if (!clear) return;
    let m;
    try { m = JSON.parse(dec.decode(clear)); } catch (_) { return; }
    const r = this.roster;
    if (m.to && m.to !== this.me) {
      if (m.t === 'kick' && r.can(from, 'removeMembers') && r.outranks(from, m.to)) { this.present.delete(m.to); this.change(); }
      return;
    }
    if (r.banned(from)) return;
    if (m.t === 'hi') { this.present.set(from, { name: String(m.n ?? ''), guest: !!m.g, voice: !!m.a, username: m.u ?? null }); this.change(); }
    else if (m.t === 'msg') { if (r.can(from, 'chat')) this.add([{ id: m.id, x: String(m.x ?? '').trim().slice(0, 4000), at: m.at, n: String(m.n ?? ''), f: from }]); }
    else if (m.t === 'del') { const x = this.messages.find((y) => y.id === m.id); if (x && (x.f === from || r.isOwner(from) || (r.can(from, 'manageMessages') && r.outranks(from, x.f)))) this.drop(m.id); }
    else if (m.t === 'sync?') {
      if (this.answers(from)) { const missed = this.messages.filter((x) => x.at > (m.since ?? 0)); if (missed.length) this.say({ t: 'hist', to: from, m: missed.map((x) => ({ id: x.id, x: x.x, at: x.at, n: x.n, f: x.f })) }); }
      if (r.j.s && (typeof m.v !== 'number' || r.version > m.v)) this.say({ t: 'roster', to: from, r: r.j });
    }
    else if (m.t === 'hist') this.add((m.m ?? []).filter((x) => typeof x.f === 'string'));
    else if (m.t === 'roster') {
      const next = new Roster(m.r, this.owner, this.ownerId);
      if ((m.r?.v ?? 0) > r.version && (await next.trusted())) {
        this.roster = next;
        if (next.banned(this.me)) this.putOut = 'You were banned from this space.';
        this.keep();
        this.change();
      }
    }
    else if (m.t === 'mute') { if (r.can(from, 'muteOthers') && r.outranks(from, m.who)) { m.on ? this.heldMutes.add(m.who) : this.heldMutes.delete(m.who); this.change(); } }
    else if (m.t === 'kick') { if (r.can(from, 'removeMembers') && r.outranks(from, this.me)) { this.putOut = r.banned(this.me) ? 'You were banned from this space.' : 'You were removed from this space.'; this.change(); } }
  }
}
