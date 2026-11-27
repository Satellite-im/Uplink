// The Uplink side's wire format, ported from site/join/voice.js (the browser join page) and lib/net/crypto.dart: a
// space's room names, tokens and key made from its seed, everything said in a room sealed with AES-GCM, and the
// hub's room frames. Pure: node:crypto only, no network. test/protocol.test.js checks it against voice.js itself.
import { createCipheriv, createDecipheriv, createHash, createHmac, randomBytes } from 'node:crypto';

// Bytes (a Buffer or any typed array) as lowercase hex, hex as bytes, and a SHA-256 digest.
export const hex = (b) => Buffer.from(b.buffer ? new Uint8Array(b.buffer, b.byteOffset, b.byteLength) : b).toString('hex');
export const unhex = (h) => Buffer.from(String(h ?? ''), 'hex');
export const sha256 = (b) => createHash('sha256').update(b).digest();

/** HMAC-SHA256(key, "ghost-net <label>" || 0x01), as voice.js's derive. */
export function derive(key, label) {
  return createHmac('sha256', key).update(Buffer.concat([Buffer.from(`ghost-net ${label}`, 'utf8'), Buffer.from([1])])).digest();
}

const AAD = Buffer.from('ghost-net-v1', 'utf8');

/** iv (12) || ciphertext || tag (16), AES-256-GCM with the AAD "ghost-net-v1": voice.js's seal. */
export function seal(key, clear) {
  const iv = randomBytes(12);
  const c = createCipheriv('aes-256-gcm', key, iv, { authTagLength: 16 });
  c.setAAD(AAD);
  return Buffer.concat([iv, c.update(clear), c.final(), c.getAuthTag()]);
}

/** The clear bytes, or null when the packet is not sealed with this key (or was changed). */
export function open(key, sealed) {
  try {
    const b = Buffer.from(sealed);
    // Shorter than an iv and a tag: not a sealed packet at all.
    if (b.length < 28) return null;
    const d = createDecipheriv('aes-256-gcm', key, b.subarray(0, 12), { authTagLength: 16 });
    d.setAAD(AAD);
    d.setAuthTag(b.subarray(b.length - 16));
    return Buffer.concat([d.update(b.subarray(12, b.length - 16)), d.final()]);
  } catch {
    return null;
  }
}

// A JSON message sealed, and one opened: null unless it opens with this key and is a JSON object (not a list).
export const sealJson = (key, what) => seal(key, Buffer.from(JSON.stringify(what), 'utf8'));
export function openJson(key, sealed) {
  const clear = open(key, sealed);
  if (!clear) return null;
  try {
    const m = JSON.parse(clear.toString('utf8'));
    return m && typeof m === 'object' && !Array.isArray(m) ? m : null;
  } catch {
    return null;
  }
}

/**
 * A space's rooms from its seed (64 hex): the call's room (voice room / voice token) and its chat room (hangout room /
 * hangout token), both sealed with the one key (voice key), as voice.js's Hangout and Chat make them.
 */
export function spaceKeys(seedHex) {
  if (!/^[0-9a-f]{64}$/.test(seedHex ?? '')) throw new Error('not a seed');
  const s = unhex(seedHex);
  return {
    voiceRoom: hex(derive(s, 'voice room').subarray(0, 16)),
    voiceToken: hex(derive(s, 'voice token')),
    chatRoom: hex(derive(s, 'hangout room').subarray(0, 16)),
    chatToken: hex(derive(s, 'hangout token')),
    key: derive(s, 'voice key'),
  };
}

/** The first byte of a binary hub frame that is for a room. */
export const TO_ROOM = 2;

/** What a member sends to the hub for a room: [2][room, 16 bytes][sealed]. */
export function roomFrame(room, sealed) {
  return Buffer.concat([Buffer.from([TO_ROOM]), unhex(room), Buffer.from(sealed)]);
}

/** What the hub hands on: [2][room][from, 16 bytes][sealed] -> { room, from, sealed }, or null. */
export function parseRoomFrame(data) {
  const d = Buffer.from(data.buffer ? new Uint8Array(data.buffer, data.byteOffset ?? 0, data.byteLength) : data);
  if (d.length < 34 || d[0] !== TO_ROOM) return null;
  return { room: hex(d.subarray(1, 17)), from: hex(d.subarray(17, 33)), sealed: d.subarray(33) };
}

/** [sdp] with Opus asked for at its highest (lib/voice/voice.dart and voice.js's highestOpus, line for line). */
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
      for (const kv of f[2].split(';')) {
        const i = kv.indexOf('=');
        if (i > 0) p[kv.slice(0, i).trim()] = kv.slice(i + 1).trim();
      }
      Object.assign(p, want);
      out.push(`a=fmtp:${f[1]} ${Object.entries(p).map(([k, v]) => `${k}=${v}`).join(';')}`);
      continue;
    }
    out.push(l);
    const r = l.match(opus);
    if (r && !lines.some((x) => x.startsWith(`a=fmtp:${r[1]} `))) out.push(`a=fmtp:${r[1]} ${Object.entries(want).map(([k, v]) => `${k}=${v}`).join(';')}`);
  }
  return out.join('\r\n');
}

/** A chat message id: 8 random bytes in hex, as voice.js's Chat.send makes them. */
export const messageId = () => randomBytes(8).toString('hex');
