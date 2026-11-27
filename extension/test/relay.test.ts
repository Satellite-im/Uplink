import { afterEach, describe, expect, it } from 'vitest';
import { p256 } from '@noble/curves/p256';
import { sha256 } from '@noble/hashes/sha256';
import { hex, identityPublicOf, randomIdentity, unb64 } from '../src/ghost/crypto.ts';
import { helloBytes, hostOf, Hub } from '../src/ghost/relay.ts';

// The hub sign-in v2 (messaging/relay/lib/hub.dart `greetingV2`, relay/README.md "Signing in"): once any app of an
// account signs in with v2 at a relay, that relay takes no v1 from the account's key again, so the extension signs v2
// wherever the hub's hello offers it, bound to the host it dialled, byte for byte as the relay checks it.

const NONCE = Array.from({ length: 32 }, (_, i) => i.toString(16).padStart(2, '0')).join('');

describe('what is signed', () => {
  it('the host is the one dialled, lower case, with its port only where it is not the scheme\'s own', () => {
    expect(hostOf('wss://gogho.st/hub')).toBe('gogho.st');
    expect(hostOf('wss://GoGho.ST:443/hub')).toBe('gogho.st');
    expect(hostOf('ws://127.0.0.1:18912/hub')).toBe('127.0.0.1:18912');
    expect(hostOf('ws://localhost:80/hub')).toBe('localhost');
    expect(hostOf('wss://[::1]:8443/hub')).toBe('[::1]:8443');
  });

  it('v2 is the relay\'s own bytes (Hub.signedV2 for gogho.st and the number 0..31); v1 as before', () => {
    expect(hex(helloBytes(NONCE, 'gogho.st'))).toBe('67686f73742d6875622076322008676f67686f2e7374000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f');
    expect(hex(helloBytes(NONCE, null))).toBe(hex(new TextEncoder().encode('ghost-hub v1 ')) + NONCE);
  });
});

describe('the sign-in said', () => {
  const real = globalThis.WebSocket;
  afterEach(() => {
    globalThis.WebSocket = real;
  });

  /** Connects through a stand-in for the browser's WebSocket; what the extension sends once the hub says `hello`. */
  async function signIn(hello: Record<string, unknown>, url = 'wss://gogho.st/hub'): Promise<{ sent: Record<string, unknown>; key: Uint8Array }> {
    const sent: string[] = [];
    let socket: { onmessage?: (e: { data: unknown }) => void } | null = null;
    class StandIn {
      binaryType = 'blob';
      onmessage?: (e: { data: unknown }) => void;
      onerror?: () => void;
      onclose?: () => void;
      constructor(readonly url: string) {
        socket = this;
      }
      send(data: string) {
        sent.push(data);
        queueMicrotask(() => this.onmessage?.({ data: JSON.stringify({ ok: true, held: 0 }) }));
      }
      close() {}
    }
    globalThis.WebSocket = StandIn as unknown as typeof WebSocket;
    const scalar = randomIdentity();
    const connected = Hub.connect(scalar, 'test', url);
    socket!.onmessage!({ data: JSON.stringify(hello) });
    (await connected).close();
    return { sent: JSON.parse(sent[0]), key: identityPublicOf(scalar) };
  }

  const verifies = (key: Uint8Array, sig: string, message: Uint8Array) => p256.verify(unb64(sig), sha256(message), key, { prehash: false });

  it('to a hub that offers v2: v2, bound to the host dialled, and the relay\'s check holds', async () => {
    const { sent, key } = await signIn({ hello: NONCE, peek: true, react: true, v2: true });
    expect(sent.v).toBe(2);
    expect(sent.host).toBe('gogho.st');
    expect(verifies(key, sent.sig as string, helloBytes(NONCE, 'gogho.st'))).toBe(true);
    expect(verifies(key, sent.sig as string, helloBytes(NONCE, null))).toBe(false);
  });

  it('to a hub from before: v1, as ever', async () => {
    const { sent, key } = await signIn({ hello: NONCE, peek: true, react: true });
    expect('v' in sent).toBe(false);
    expect('host' in sent).toBe(false);
    expect(verifies(key, sent.sig as string, helloBytes(NONCE, null))).toBe(true);
  });
});
