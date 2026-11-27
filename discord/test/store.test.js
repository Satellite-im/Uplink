import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { TokenStore } from '../src/store.js';

// The links (src/store.js): tokens made, read and revoked, and what the file on disk holds.

test('a token is 32 lowercase hex digits and reads its server', () => {
  const store = new TokenStore(null);
  const token = store.add('g1');
  assert.match(token, /^[0-9a-f]{32}$/);
  assert.equal(store.guildOf(token), 'g1');
  assert.equal(store.guildOf(token.toUpperCase()), null);
  assert.equal(store.guildOf('0'.repeat(32)), null);
  assert.equal(store.guildOf(undefined), null);
});

test('each claim is a new token; unlink revokes them all for that server only', () => {
  const store = new TokenStore(null);
  const a = store.add('g1'), b = store.add('g1'), c = store.add('g2');
  assert.notEqual(a, b);
  assert.equal(store.countGuild('g1'), 2);
  assert.equal(store.revokeGuild('g1'), 2);
  assert.equal(store.guildOf(a), null);
  assert.equal(store.guildOf(b), null);
  assert.equal(store.guildOf(c), 'g2');
  assert.equal(store.revokeGuild('g1'), 0);
});

test('links survive a restart; the file holds hashes, not tokens, and no temporary file is left', () => {
  const dir = mkdtempSync(join(tmpdir(), 'ghost-discord-'));
  const store = TokenStore.open(dir);
  const token = store.add('g1');
  const file = join(dir, 'links.json');
  const text = readFileSync(file, 'utf8');
  assert.ok(!text.includes(token));
  assert.equal(JSON.parse(text).links.length, 1);
  assert.deepEqual(readdirSync(dir), ['links.json']);
  assert.equal(statSync(file).mode & 0o777, 0o600);
  const again = TokenStore.open(dir);
  assert.equal(again.guildOf(token), 'g1');
  again.revokeGuild('g1');
  assert.equal(TokenStore.open(dir).guildOf(token), null);
});
