#!/usr/bin/env node
// Checks an Uplink proof (docs/proofs.md) with nothing but Node's own library: no server is asked anything.
//
//   node tool/check-proof.mjs proof.txt
//   pbpaste | node tool/check-proof.mjs
//
// Prints the account (its did:key), when it says it was signed and the statement, and exits 0 where the signature is
// that account's over those words; 1 where it isn't, or nothing could be read.
import { createPublicKey, verify, ECDH } from 'node:crypto';
import { readFileSync } from 'node:fs';

const BEGIN = '-----BEGIN GHOST PROOF-----';
const END = '-----END GHOST PROOF-----';
const ALPHABET = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

function fail(why) {
  console.log(`Does not check out: ${why}`);
  process.exit(1);
}

function base58(text) {
  let n = 0n;
  for (const c of text) {
    const d = ALPHABET.indexOf(c);
    if (d < 0) return null;
    n = n * 58n + BigInt(d);
  }
  let hex = n.toString(16);
  if (hex.length % 2) hex = '0' + hex;
  const zeros = text.match(/^1*/)[0].length;
  return Buffer.concat([Buffer.alloc(zeros), n === 0n ? Buffer.alloc(0) : Buffer.from(hex, 'hex')]);
}

// Spaces and tabs off both ends of a line, and nothing else (lib/me/identity.dart trims the same).
const trim = (x) => x.replace(/^[ \t]+|[ \t]+$/g, '');

// The statement as it is signed: line ends made \n, each line trimmed, blank lines at either end dropped.
function tidy(lines) {
  const l = lines.map(trim);
  while (l.length && !l[0]) l.shift();
  while (l.length && !l[l.length - 1]) l.pop();
  return l.join('\n');
}

const text = readFileSync(process.argv[2] ?? 0, 'utf8').replace(/\r\n?/g, '\n');
const a = text.indexOf(BEGIN);
const b = a < 0 ? -1 : text.indexOf(END, a + BEGIN.length);
if (a < 0 || b < 0) fail('no proof found (it runs from its BEGIN line to its END line)');
if (b + END.length - a > 8192) fail('the block is too long to be a proof');

const lines = text.slice(a + BEGIN.length, b).split('\n').map(trim);
while (lines.length && !lines[0]) lines.shift();
const fields = {};
let i = 0;
for (; i < lines.length && lines[i]; i++) {
  const at = lines[i].indexOf(':');
  if (at < 0) fail(`a line was changed: "${lines[i]}"`);
  fields[trim(lines[i].slice(0, at)).toLowerCase()] = trim(lines[i].slice(at + 1));
}
const did = fields.account ?? '';
const time = fields.signed ?? '';
const statement = tidy(lines.slice(i));

// did:key:z + base58btc(0x80 0x24 + the 33-byte compressed P-256 key)
if (!did.startsWith('did:key:z')) fail('the account is not a did:key');
const raw = base58(did.slice('did:key:z'.length));
if (!raw || raw.length !== 35 || raw[0] !== 0x80 || raw[1] !== 0x24) fail('the account is not a P-256 did:key');
let point;
try {
  point = ECDH.convertKey(raw.subarray(2), 'prime256v1', undefined, undefined, 'uncompressed');
} catch {
  fail('the account\'s key is not a point on P-256');
}
const key = createPublicKey({
  key: { kty: 'EC', crv: 'P-256', x: point.subarray(1, 33).toString('base64url'), y: point.subarray(33).toString('base64url') },
  format: 'jwk',
});

if (!/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/.test(time)) fail('the Signed line is missing or not a time like 2026-11-23T10:15:07Z');
const sigText = (fields.signature ?? '').replace(/\+/g, '-').replace(/\//g, '_');
if (!/^[A-Za-z0-9_-]{86}$/.test(sigText)) fail('the signature is missing, cut short or changed');
const signature = Buffer.from(sigText, 'base64url');
if (signature.length !== 64) fail('the signature is missing or cut short');

const message = Buffer.from(`ghost-proof v1\n${did}\n${time}\n${statement}`, 'utf8');
const good = verify('sha256', message, { key, dsaEncoding: 'ieee-p1363' }, signature);

console.log(`Account:   ${did}`);
console.log(`Signed:    ${time}`);
console.log(`Statement: ${statement.split('\n').join('\n           ')}`);
if (!good) fail('the signature is not that account\'s over these words and this time');
console.log('Checks out: signed by that account.');
