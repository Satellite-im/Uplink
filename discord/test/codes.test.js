import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ALPHABET, CODE_TTL_MS, Codes } from '../src/codes.js';

// Link codes (src/codes.js): their shape, one use, ten minutes, and the limit a server.

test('a code is six characters from the alphabet without look-alikes', () => {
  const codes = new Codes();
  for (let i = 0; i < 200; i++) {
    const code = codes.issue('g');
    assert.match(code, /^[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{6}$/);
  }
  assert.ok(!/[01OIL]/.test(ALPHABET));
});

test('a code works once', () => {
  const codes = new Codes();
  const code = codes.issue('g1');
  assert.equal(codes.take(code), 'g1');
  assert.equal(codes.take(code), null);
});

test('a code is read without regard to case or spaces round it', () => {
  const codes = new Codes();
  const code = codes.issue('g1');
  assert.equal(codes.take(`  ${code.toLowerCase()} `), 'g1');
});

test('a code expires after ten minutes', () => {
  let t = 1_000_000;
  const codes = new Codes({ now: () => t });
  const a = codes.issue('g1');
  const b = codes.issue('g1');
  t += CODE_TTL_MS - 1;
  assert.equal(codes.take(a), 'g1');
  t += 1;
  assert.equal(codes.take(b), null);
});

test('wrong, malformed and non-string codes are refused', () => {
  const codes = new Codes();
  codes.issue('g1');
  for (const bad of ['', 'AAAAAA0', 'OOOOOO', 'ABC12', null, 42, {}, undefined]) assert.equal(codes.take(bad), null);
});

test('dropGuild cancels a server\'s waiting codes only', () => {
  const codes = new Codes();
  const a = codes.issue('g1');
  const b = codes.issue('g2');
  codes.dropGuild('g1');
  assert.equal(codes.take(a), null);
  assert.equal(codes.take(b), 'g2');
});

test('a server has at most five codes waiting', () => {
  const codes = new Codes();
  const made = Array.from({ length: 7 }, () => codes.issue('g1'));
  assert.equal(codes.size, 5);
  assert.equal(codes.take(made[0]), null);
  assert.equal(codes.take(made[6]), 'g1');
});
