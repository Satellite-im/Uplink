// Seeds: random, one per channel, kept across restarts, never made from the channel's ids; and the bridge's own key.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, createHmac } from 'node:crypto';
import { mkdtempSync, readFileSync, readdirSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { makeIdentity } from '../src/bridge/hub.js';
import { BridgeStore } from '../src/bridge/store.js';

const G = '100000000000000001';
const C1 = '400000000000000004';
const C2 = '400000000000000005';

test('a seed is 64 hex, the same each time for a channel, different for another channel', () => {
  const s = new BridgeStore(null);
  const a = s.seedFor(G, C1);
  assert.match(a, /^[0-9a-f]{64}$/);
  assert.equal(s.seedFor(G, C1), a);
  assert.notEqual(s.seedFor(G, C2), a);
  assert.throws(() => s.seedFor('guild', C1), /not a Discord id/);
});

test('a seed is random, not a function of public ids: two stores give the same channel different seeds', () => {
  const a = new BridgeStore(null).seedFor(G, C1);
  const b = new BridgeStore(null).seedFor(G, C1);
  assert.notEqual(a, b);
  for (const guess of [createHash('sha256').update(`${G}:${C1}`).digest('hex'), createHmac('sha256', G).update(C1).digest('hex')]) assert.notEqual(a, guess);
  // It is exactly the random bytes it was given.
  const fixed = new BridgeStore(null, { random: (n) => Buffer.alloc(n, 0xab) });
  assert.equal(fixed.seedFor(G, C1), 'ab'.repeat(32));
});

test('seeds, webhooks and the key survive a restart; the file is the service\'s alone; no temporary file is left', () => {
  const dir = mkdtempSync(join(tmpdir(), 'ghost-bridge-'));
  try {
    const s = BridgeStore.open(dir);
    const seed = s.seedFor(G, C1);
    s.setWebhook(G, C1, { id: '500000000000000005', token: 'tok' });
    const pem = s.identityPem(() => makeIdentity().pem);
    const id = makeIdentity(pem).id;

    const again = BridgeStore.open(dir);
    assert.equal(again.seedFor(G, C1), seed);
    assert.deepEqual(again.webhook(G, C1), { id: '500000000000000005', token: 'tok' });
    assert.deepEqual([...again.webhookIds()], ['500000000000000005']);
    assert.equal(makeIdentity(again.identityPem(() => assert.fail('a new key was made'))).id, id);
    again.setWebhook(G, C1, null);
    assert.equal(BridgeStore.open(dir).webhook(G, C1), null);

    assert.deepEqual(readdirSync(dir), ['bridges.json']);
    assert.equal(statSync(join(dir, 'bridges.json')).mode & 0o777, 0o600);
    assert.equal(statSync(dir).mode & 0o077, 0);
    assert.match(readFileSync(join(dir, 'bridges.json'), 'utf8'), /"version": 1/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
