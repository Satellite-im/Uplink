#!/usr/bin/env node
/**
 * Holds web/argon2id.js, the file as it is committed, to test/vectors/argon2id.json: the vectors the app's Dart half
 * is held to too (test/argon2_test.dart). tool/build-web.mjs runs this before every build, whether or not the
 * extension's packages are installed (tool/web/build-argon2.mjs --check, which needs them, says whether the file is what
 * its script writes; this says whether the file that ships gives the right answers).
 *
 *   node tool/web/check-argon2.mjs
 *
 * The file is run as a script, as tool/web/build-argon2.mjs runs what it builds: it is no worker here, so it defines
 * `ghostArgon2id` and does nothing else. (In a vm context of its own it runs twenty times slower, two minutes for the
 * vectors.) Each vector is asked of that, and must give its key.
 */
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const hex = (bytes) => [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');

/** The vectors run against [root]'s web/argon2id.js: how many, and the slowest in ms. Throws on the first that fails. */
export function checkArgon2(root) {
  const code = readFileSync(join(root, 'web', 'argon2id.js'), 'utf8');
  delete globalThis.ghostArgon2id;
  new Function(code)();
  const stretch = globalThis.ghostArgon2id;
  delete globalThis.ghostArgon2id;
  if (typeof stretch !== 'function') throw new Error('web/argon2id.js does not define ghostArgon2id outside a worker.');
  const bytes = (list) => Uint8Array.from(list);
  const { vectors } = JSON.parse(readFileSync(join(root, 'test', 'vectors', 'argon2id.json'), 'utf8'));
  if (!vectors.some((v) => v.m === 65536 && v.t === 3 && v.p === 1)) throw new Error('no vector has the account\'s own settings (64 MiB, 3 passes, 1 lane).');
  let slowest = 0;
  for (const v of vectors) {
    const began = Date.now();
    const got = hex(stretch(bytes(new TextEncoder().encode(v.password)), bytes(v.salt.match(/../g).map((h) => parseInt(h, 16))), v.m, v.t, v.p, v.key.length / 2));
    slowest = Math.max(slowest, Date.now() - began);
    if (got !== v.key) throw new Error(`web/argon2id.js fails a vector (${v.m} KiB, ${v.t} passes, ${v.p} lanes, ${JSON.stringify(v.password)}): ${got}, not ${v.key}.`);
  }
  return { count: vectors.length, slowest };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const { count, slowest } = checkArgon2(join(dirname(fileURLToPath(import.meta.url)), '..', '..'));
    console.log(`web/argon2id.js gives all ${count} vectors (the slowest in ${slowest} ms here).`);
  } catch (e) {
    console.error(`check-argon2: ${e.message}`);
    process.exit(1);
  }
}
