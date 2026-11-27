// The cryptography of an Uplink account, ported to the browser from the app's Dart so that the extension
// arrives at the same keys the app does: messaging/lib/account/account_crypto.dart and messaging/lib/net/crypto.dart.
// Every constant and label here is copied from there; a mismatch would seal a blob the app cannot open.
//
// - Recovery words -> BIP-39 seed (PBKDF2-HMAC-SHA512, 2048 rounds, salt "mnemonic").
// - Seed -> secp256k1 account key (BIP-32 m/44'/60'/0'/0/0); its EIP-55 address is the account id; it signs the
//   EIP-191 messages the relay checks (acct-seed).
// - Seed -> P-256 "Uplink identity" (HKDF-SHA256); a device is known to the hub by it, and all of an account's devices
//   share it. The extension connects to the hub as this identity.
// - The sealed backup (opened with the seed) carries the real identity private key and `kept_key`, from which the
//   cURL-entry seal key is derived.
import { secp256k1 } from '@noble/curves/secp256k1';
import { p256 } from '@noble/curves/p256';
import { keccak_256 } from '@noble/hashes/sha3';
import { sha256 } from '@noble/hashes/sha2';
import { hmac } from '@noble/hashes/hmac';
import { sha512 } from '@noble/hashes/sha2';
import { pbkdf2Async } from '@noble/hashes/pbkdf2';
import { argon2id } from '@noble/hashes/argon2';

export type Bytes = Uint8Array;

const enc = new TextEncoder();
export const utf8 = (s: string): Bytes => enc.encode(s);
export const hex = (b: Bytes): string => Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('');
export function unhex(s: string): Bytes {
  const out = new Uint8Array(Math.floor(s.length / 2));
  for (let i = 0; i < out.length; i++) out[i] = parseInt(s.substr(i * 2, 2), 16);
  return out;
}
export const concat = (...parts: Bytes[]): Bytes => {
  const total = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(total);
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
};
export const b64 = (b: Bytes): string => btoa(String.fromCharCode(...b));
export const unb64 = (s: string): Bytes => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
export const randomBytes = (n: number): Bytes => crypto.getRandomValues(new Uint8Array(n));

const bigOf = (b: Bytes): bigint => {
  let v = 0n;
  for (const x of b) v = (v << 8n) | BigInt(x);
  return v;
};
const fixed = (v: bigint, n = 32): Bytes => {
  const out = new Uint8Array(n);
  for (let i = n - 1; i >= 0; i--) {
    out[i] = Number(v & 0xffn);
    v >>= 8n;
  }
  return out;
};

// --- BIP-39 ---------------------------------------------------------------------------------------------------------

export const tidyWords = (typed: string): string[] => typed.trim().toLowerCase().split(/[\s,]+/).filter((w) => w.length > 0);

/** BIP-39 seed: PBKDF2-HMAC-SHA512, 2048 rounds, salt "mnemonic", 64 bytes. Matches AccountCrypto.seedOf. */
export const seedOf = (words: string[]): Promise<Bytes> =>
  pbkdf2Async(sha512, utf8(words.join(' ')), utf8('mnemonic'), { c: 2048, dkLen: 64 });

// --- the account key (BIP-32, secp256k1) ----------------------------------------------------------------------------

const K1_N = secp256k1.CURVE.n;
const ETH_PATH = [0x8000002c, 0x8000003c, 0x80000000, 0, 0];

const hmac512 = (key: Bytes, data: Bytes): Bytes => hmac(sha512, key, data);

/** The private key BIP-32 makes from `seed` down m/44'/60'/0'/0/0. Matches AccountCrypto.derive. */
export function accountKeyOf(seed: Bytes): Bytes {
  let i = hmac512(utf8('Bitcoin seed'), seed);
  let key = bigOf(i.slice(0, 32));
  let chain = i.slice(32);
  if (key === 0n || key >= K1_N) throw new Error('unusable seed');
  for (const index of ETH_PATH) {
    const data = index >= 0x80000000
      ? concat(new Uint8Array([0]), fixed(key))
      : secp256k1.getPublicKey(fixed(key), true);
    const suffix = new Uint8Array([(index >>> 24) & 0xff, (index >>> 16) & 0xff, (index >>> 8) & 0xff, index & 0xff]);
    i = hmac512(chain, concat(data, suffix));
    const tweak = bigOf(i.slice(0, 32));
    if (tweak >= K1_N) throw new Error('unusable index');
    key = (tweak + key) % K1_N;
    if (key === 0n) throw new Error('unusable index');
    chain = i.slice(32);
  }
  return fixed(key);
}

/** EIP-55 checksummed address. Matches AccountCrypto.checksummed. */
export function checksummed(hex40: string): string {
  const lower = hex40.toLowerCase().replace(/^0x/, '');
  const h = hex(keccak_256(utf8(lower)));
  let out = '0x';
  for (let i = 0; i < lower.length; i++) out += parseInt(h[i], 16) >= 8 ? lower[i].toUpperCase() : lower[i];
  return out;
}

/** The account's address: Keccak-256 of the 64-byte public key, last 20 bytes, EIP-55. Matches addressOf. */
export function addressOf(accountKey: Bytes): string {
  const pub = secp256k1.getPublicKey(accountKey, false); // 65 bytes: 0x04 || x || y
  return checksummed(hex(keccak_256(pub.slice(1)).slice(12)));
}

/** EIP-191 personal-message hash. Matches AccountCrypto.personalHash. */
const personalHash = (message: Bytes): Bytes => keccak_256(concat(utf8(`\x19Ethereum Signed Message:\n${message.length}`), message));

/** `accountKey`'s recoverable EIP-191 signature over `message`: r, s (low), v (27/28), 65 bytes. Matches sign(). */
export function signAccount(accountKey: Bytes, message: Bytes): Bytes {
  const sig = secp256k1.sign(personalHash(message), accountKey, { lowS: true, prehash: false });
  return concat(fixed(sig.r), fixed(sig.s), new Uint8Array([27 + sig.recovery]));
}

// --- HKDF and what the seed makes besides the address ---------------------------------------------------------------

/** HKDF-SHA256 as the app writes it (AccountCrypto.hkdf): extract then expand, `length` bytes. */
export function hkdf(ikm: Bytes, salt: string, info: string, length = 32): Bytes {
  const prk = hmac(sha256, utf8(salt), ikm);
  const infoBytes = utf8(info);
  const out: number[] = [];
  let block: Bytes = new Uint8Array(0);
  for (let i = 1; out.length < length; i++) {
    block = hmac(sha256, prk, concat(block, infoBytes, new Uint8Array([i])));
    out.push(...block);
  }
  return new Uint8Array(out.slice(0, length));
}

const ACCOUNT_SALT = 'ghost-account v1';
const P256_N = p256.CURVE.n;

/** A handle as the app compares it (me.dart's tidyHandle): trimmed, lower case, no leading "@". */
export function tidyHandle(handle: string): string {
  let h = handle.trim().toLowerCase();
  while (h.startsWith('@')) h = h.slice(1);
  return h;
}

/** A throwaway P-256 identity, for the hub connection that only signs in (acct-find/acct-get, acct-seed). */
export const randomIdentity = (): Bytes => p256.utils.randomPrivateKey();

/** The P-256 identity scalar the seed makes. Matches AccountCrypto.identityOf. */
export function identityScalarOf(seed: Bytes): Bytes {
  for (let i = 0; ; i++) {
    const d = hkdf(seed, ACCOUNT_SALT, `ghost identity p256 v1|${i}`);
    const v = bigOf(d);
    if (v > 0n && v < P256_N) return d;
  }
}

/** The 33-byte compressed public key of a P-256 scalar. */
export const identityPublicOf = (scalar: Bytes): Bytes => p256.getPublicKey(scalar, true);

/** The id the hub knows an identity by: first 16 bytes of SHA-256 of its 33-byte public key, hex. Matches idOf. */
export const idOf = (publicKey: Bytes): string => hex(sha256(publicKey).slice(0, 16));

/** The key the seed's copy of the backup is sealed with. Matches AccountCrypto.seedSealKey. */
export const seedSealKey = (seed: Bytes): Bytes => hkdf(seed, ACCOUNT_SALT, 'ghost backup seal v1');

// --- P-256 signing (for the hub handshake) --------------------------------------------------------------------------

/** An identity's signature over `message` (SHA-256 then ECDSA P-256): r then s, 64 bytes. Matches NetCrypto.sign. */
export function signIdentity(scalar: Bytes, message: Bytes): Bytes {
  const sig = p256.sign(sha256(message), scalar, { lowS: true, prehash: false });
  return concat(fixed(sig.r), fixed(sig.s));
}

// --- sealing (AES-256-GCM) ------------------------------------------------------------------------------------------

// Web Crypto's types want an ArrayBuffer-backed view; noble returns the generic Uint8Array. The bytes are identical.
const bs = (b: Bytes): BufferSource => b as unknown as BufferSource;

async function aesKey(key: Bytes): Promise<CryptoKey> {
  return crypto.subtle.importKey('raw', bs(key), { name: 'AES-GCM' }, false, ['encrypt', 'decrypt']);
}

/** `clear` sealed with `key`: 12 random bytes, then AES-256-GCM output with its tag. Matches NetCrypto.seal/gcmSeal. */
export async function gcmSeal(key: Bytes, clear: Bytes, aad: Bytes): Promise<Bytes> {
  const nonce = randomBytes(12);
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: bs(nonce), additionalData: bs(aad) }, await aesKey(key), bs(clear)));
  return concat(nonce, ct);
}

/** What was sealed, or null when it cannot be opened. Matches NetCrypto.open/gcmOpen. */
export async function gcmOpen(key: Bytes, sealed: Bytes, aad: Bytes): Promise<Bytes | null> {
  if (sealed.length < 28) return null;
  try {
    const clear = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: bs(sealed.slice(0, 12)), additionalData: bs(aad) }, await aesKey(key), bs(sealed.slice(12)));
    return new Uint8Array(clear);
  } catch {
    return null;
  }
}

const NET_AAD = utf8('ghost-net-v1');
const accountAad = (address: string, kind: string): Bytes => utf8(`ghost-account v1|${address.toLowerCase()}|${kind}`);

/** A key for one purpose made from another. Matches NetCrypto.derive. */
export const derive = (key: Bytes, label: string): Bytes => hmac(sha256, key, concat(utf8(`ghost-net ${label}`), new Uint8Array([1])));

/** Seal/open the routes' way (AAD "ghost-net-v1"): what the kept blobs use. */
export const netSeal = (key: Bytes, clear: Bytes): Promise<Bytes> => gcmSeal(key, clear, NET_AAD);
export const netOpen = (key: Bytes, sealed: Bytes): Promise<Bytes | null> => gcmOpen(key, sealed, NET_AAD);

/** Open the seed-sealed account backup: AES-GCM with the account AAD, then gunzip the JSON. */
export async function openSeedBackup(seed: Bytes, address: string, blob: string): Promise<AccountBackup | null> {
  let outer: { v?: number; k?: string; c?: string };
  try {
    outer = JSON.parse(blob);
  } catch {
    return null;
  }
  if (outer.v !== 1 || outer.k !== 'seed' || typeof outer.c !== 'string') return null;
  const gz = await gcmOpen(seedSealKey(seed), unb64(outer.c), accountAad(address, 'seed'));
  if (!gz) return null;
  const json = await gunzip(gz);
  try {
    const m = JSON.parse(new TextDecoder().decode(json));
    if (m.v !== 1 || typeof m.i !== 'string') return null;
    return { words: String(m.w ?? '').split(' '), identity: m.i as string, keptKey: (m.k as string) ?? '', username: (m.u as string) ?? '' };
  } catch {
    return null;
  }
}

export interface AccountBackup {
  words: string[];
  /** The Uplink identity's private key, 32 bytes as hex. */
  identity: string;
  /** The key Uplink's own kept lists (and ours) are sealed with. */
  keptKey: string;
  username: string;
}

async function gunzip(data: Bytes): Promise<Bytes> {
  const ds = new DecompressionStream('gzip');
  const stream = new Response(new Blob([data as BlobPart]).stream().pipeThrough(ds));
  return new Uint8Array(await stream.arrayBuffer());
}

/** The seal key for the synced cURL entries, from the account's BIP-39 seed. Matches me.dart's `_curlKey` (HKDF of
 * the seed under 'ghost curl v1'), so the app and the extension arrive at the same key. */
export const curlKeyOf = (seed: Bytes): Bytes => hkdf(seed, ACCOUNT_SALT, 'ghost curl v1');

// --- the password (Argon2id), for signing in by username + password -------------------------------------------------

/** Argon2id the account's way (AccountCrypto.passwordKey): 32 bytes, version 0x13. `m` is KiB. */
export const passwordKey = (password: string, salt: Bytes, m: number, t: number, p: number): Bytes =>
  argon2id(utf8(password), salt, { m, t, p, dkLen: 32, version: 0x13 });

/** The proof shown to the relay for `acct-get` (PasswordKey.auth): HKDF of the key under its own label. */
export const passwordAuth = (pwKey: Bytes): Bytes => hkdf(pwKey, 'ghost-account v1', 'password auth v1');

/** Open the password-sealed backup (`{v,k:'argon2id',m,t,p,s,c}`), then gunzip. Matches openWithPasswordKey. */
export async function openPasswordBackup(blob: string, pwKey: Bytes, address: string): Promise<AccountBackup | null> {
  let outer: { v?: number; k?: string; c?: string };
  try {
    outer = JSON.parse(blob);
  } catch {
    return null;
  }
  if (outer.v !== 1 || outer.k !== 'argon2id' || typeof outer.c !== 'string') return null;
  const gz = await gcmOpen(pwKey, unb64(outer.c), accountAad(address, 'password'));
  if (!gz) return null;
  try {
    const m = JSON.parse(new TextDecoder().decode(await gunzip(gz)));
    if (m.v !== 1 || typeof m.i !== 'string') return null;
    return { words: String(m.w ?? '').split(' '), identity: m.i as string, keptKey: (m.k as string) ?? '', username: (m.u as string) ?? '' };
  } catch {
    return null;
  }
}

/** The salt + settings a password blob (or `acct-find` kdf) names. */
export interface Kdf {
  m: number;
  t: number;
  p: number;
  s: string;
}
