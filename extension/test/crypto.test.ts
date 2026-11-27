import { describe, expect, it } from 'vitest';
import { secp256k1 } from '@noble/curves/secp256k1';
import {
  accountKeyOf,
  addressOf,
  checksummed,
  curlKeyOf,
  hex,
  hkdf,
  identityPublicOf,
  identityScalarOf,
  idOf,
  netOpen,
  netSeal,
  seedOf,
  signAccount,
  tidyHandle,
  unhex,
  utf8,
} from '../src/ghost/crypto.ts';

// The canonical BIP-39 / Ethereum test mnemonic; m/44'/60'/0'/0/0 is this address in MetaMask and in the app's Dart.
const WORDS = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about'.split(' ');

describe('account derivation matches real wallets (hence the app)', () => {
  it('derives the canonical address', async () => {
    const seed = await seedOf(WORDS);
    expect(addressOf(accountKeyOf(seed))).toBe('0x9858EfFD232B4033E47d90003D41EC34EcaEda94');
  });

  it('EIP-55 checksums', () => {
    expect(checksummed('0x9858effd232b4033e47d90003d41ec34ecaeda94')).toBe('0x9858EfFD232B4033E47d90003D41EC34EcaEda94');
  });

  it('the EIP-191 signature recovers to the address', async () => {
    const seed = await seedOf(WORDS);
    const key = accountKeyOf(seed);
    const address = addressOf(key);
    const message = utf8('{"op":"seed"}');
    const sig = signAccount(key, message);
    expect(sig.length).toBe(65);
    const prefixed = utf8(`\x19Ethereum Signed Message:\n${message.length}`);
    const { keccak_256 } = await import('@noble/hashes/sha3');
    const digest = keccak_256(new Uint8Array([...prefixed, ...message]));
    const recovered = secp256k1.Signature.fromCompact(hex(sig.slice(0, 64))).addRecoveryBit(sig[64] - 27).recoverPublicKey(hex(digest));
    expect(checksummed(hex((await import('@noble/hashes/sha3')).keccak_256(recovered.toRawBytes(false).slice(1)).slice(12)))).toBe(address);
  });
});

describe('the Uplink identity', () => {
  it('is stable for a seed and yields a 32-hex id', async () => {
    const seed = await seedOf(WORDS);
    const a = idOf(identityPublicOf(identityScalarOf(seed)));
    const b = idOf(identityPublicOf(identityScalarOf(seed)));
    expect(a).toBe(b);
    expect(a).toMatch(/^[0-9a-f]{32}$/);
  });
});

describe('HKDF matches standard HKDF-SHA256 for the ASCII labels the app uses', () => {
  it('equals Node crypto.hkdfSync for a 32-byte output', async () => {
    const { hkdfSync } = await import('node:crypto');
    const ikm = unhex('0b'.repeat(22));
    const salt = 'ghost-account v1';
    const info = 'ghost identity p256 v1|0';
    const mine = hex(hkdf(ikm, salt, info, 32));
    const std = Buffer.from(hkdfSync('sha256', ikm, utf8(salt), utf8(info), 32)).toString('hex');
    expect(mine).toBe(std);
  });
});

describe('sealing round-trips with the seed-derived cURL key', () => {
  it('seals and opens an entries blob', async () => {
    const seed = await seedOf(WORDS);
    const key = curlKeyOf(seed);
    const blob = { v: 1, entries: { instagram: { cookies: { sessionid: 'abc', csrftoken: 'x', ds_user_id: '1' }, at: 123, from: 'Chrome' } } };
    const sealed = await netSeal(key, utf8(JSON.stringify(blob)));
    const back = await netOpen(key, sealed);
    expect(back).not.toBeNull();
    expect(JSON.parse(new TextDecoder().decode(back!))).toEqual(blob);
    // A different key does not open it.
    const other = curlKeyOf(await seedOf('legal winner thank year wave sausage worth useful legal winner thank yellow'.split(' ')));
    expect(await netOpen(other, sealed)).toBeNull();
  });
});

describe('tidyHandle', () => {
  it('lowercases, trims, strips @', () => {
    expect(tidyHandle('  @Matt ')).toBe('matt');
  });
});
