#!/usr/bin/env node
/**
 * Builds web/argon2id.js: the one piece of JavaScript the app in a browser carries beside itself (Matt: "the full web
 * client"). Signing in stretches the password with Argon2id (64 MiB, 3 passes). In Dart compiled to JavaScript that
 * took 37 seconds, on the page's own thread, with the page frozen; @noble/hashes' takes about a second. It is the one
 * the browser extension already uses for the same accounts (extension/src/ghost/crypto.ts), built from the extension's
 * own pinned copy, so nothing new is trusted.
 *
 *   (cd extension && npm ci)             once: the extension's packages, each checked against package-lock.json
 *   node tool/web/build-argon2.mjs       writes web/argon2id.js; commit what it writes
 *   node tool/web/build-argon2.mjs --check   fails if web/argon2id.js is not what this would write
 *
 * WHAT IS IN THE FILE
 *   Argon2id (version 0x13) and nothing else of the package, to be run as a worker: the page starts it, posts
 *   `{password, salt, memoryKiB, passes, lanes, length}` (bytes and numbers) and is posted `{key}` back, or `{error}`
 *   (lib/account/argon2_browser_web.dart). A second of work is then on a thread of its own, and the page goes on
 *   drawing. The package's own "async" Argon2 would not do: it gives way only to promises, never to the page.
 *   Run anywhere else (here, to check it) it defines `globalThis.ghostArgon2id(password, salt, memoryKiB, passes,
 *   lanes, length)` and does nothing.
 *
 * WHAT IS CHECKED, every time
 *   - The package found is the version extension/package.json pins, with the integrity package-lock.json has for it
 *     (`npm ci` held the download to that when it was installed).
 *   - What was built gives every vector in test/vectors/argon2id.json, the same file the Dart half is held to
 *     (test/argon2_test.dart). A file that fails one is not written.
 *
 * Nothing is fetched: not here (the packages are already in extension/node_modules), and not by the page, which
 * loads the file from where it came from itself.
 */
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const extension = join(root, 'extension');
const target = join(root, 'web', 'argon2id.js');
const check = process.argv.includes('--check');
const stop = (words) => {
  console.error(`build-argon2: ${words}`);
  process.exit(1);
};

const modules = join(extension, 'node_modules');
if (!existsSync(join(modules, '@noble', 'hashes', 'package.json')) || !existsSync(join(modules, 'esbuild', 'package.json'))) {
  stop('the extension\'s packages are not installed: run `npm ci` in extension/ first.');
}
const pinned = JSON.parse(readFileSync(join(extension, 'package.json'), 'utf8')).dependencies['@noble/hashes'];
const locked = JSON.parse(readFileSync(join(extension, 'package-lock.json'), 'utf8')).packages['node_modules/@noble/hashes'];
const found = JSON.parse(readFileSync(join(modules, '@noble', 'hashes', 'package.json'), 'utf8'));
if (!/^\d+\.\d+\.\d+$/.test(pinned)) stop(`extension/package.json does not pin @noble/hashes to one version (${pinned}).`);
if (found.version !== pinned || locked.version !== pinned) stop(`@noble/hashes is ${found.version} in node_modules and ${locked.version} in the lock, and ${pinned} is pinned.`);

const { build, version: esbuildVersion } = createRequire(join(extension, 'package.json'))('esbuild');
const source = `
import { argon2id } from '@noble/hashes/argon2';
const stretch = (password, salt, memoryKiB, passes, lanes, length) =>
  argon2id(password, salt, { m: memoryKiB, t: passes, p: lanes, dkLen: length, version: 0x13 });
if (typeof WorkerGlobalScope !== 'undefined' && self instanceof WorkerGlobalScope) {
  // Started as a worker: one password stretched for the page that asks, on this thread and not the page's.
  self.onmessage = (asked) => {
    try {
      const j = asked.data;
      const key = stretch(j.password, j.salt, j.memoryKiB, j.passes, j.lanes, j.length);
      self.postMessage({ key }, [key.buffer]);
    } catch (error) {
      self.postMessage({ error: String(error) });
    }
  };
} else {
  globalThis.ghostArgon2id = stretch;
}
`;
const banner = `/* Argon2id for Uplink in a browser, run as a worker: posted {password, salt, memoryKiB, passes, lanes, length}, it posts {key} back.
 * Written by tool/web/build-argon2.mjs; change that, not this.
 * From @noble/hashes ${found.version} (${locked.integrity}), bundled with esbuild ${esbuildVersion}.
 * @noble/hashes is MIT licensed: Copyright (c) 2022 Paul Miller (https://paulmillr.com). */`;
const built = await build({
  stdin: { contents: source, resolveDir: extension, sourcefile: 'ghost-argon2id.js' },
  bundle: true,
  format: 'iife',
  platform: 'browser',
  target: ['es2020'],
  minify: true,
  legalComments: 'none',
  banner: { js: banner },
  write: false,
  logLevel: 'silent',
});
const code = built.outputFiles[0].text;

// What was built, run here as the page runs it, against the vectors both halves are held to.
const hex = (bytes) => [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');
const unhex = (text) => Uint8Array.from(text.match(/../g).map((h) => parseInt(h, 16)));
// In this realm, as a page's script is in the page's: it is no worker here, so it defines the function and stops.
delete globalThis.ghostArgon2id;
new Function(code)();
const stretch = globalThis.ghostArgon2id;
if (typeof stretch !== 'function') stop('what was built does not define ghostArgon2id.');
const { vectors } = JSON.parse(readFileSync(join(root, 'test', 'vectors', 'argon2id.json'), 'utf8'));
let slowest = 0;
for (const v of vectors) {
  const began = Date.now();
  const got = hex(stretch(new TextEncoder().encode(v.password), unhex(v.salt), v.m, v.t, v.p, v.key.length / 2));
  slowest = Math.max(slowest, Date.now() - began);
  if (got !== v.key) stop(`a vector fails (${v.m} KiB, ${v.t} passes, ${v.p} lanes, ${JSON.stringify(v.password)}): ${got}, not ${v.key}.`);
}

const sha = createHash('sha256').update(code).digest('hex');
if (check) {
  if (!existsSync(target) || readFileSync(target, 'utf8') !== code) stop('web/argon2id.js is not what this builds: run it without --check and commit the file.');
  console.log(`web/argon2id.js is what this builds (${code.length} bytes, sha256 ${sha}); ${vectors.length} vectors pass.`);
} else {
  writeFileSync(target, code);
  console.log(`web/argon2id.js written: ${code.length} bytes, sha256 ${sha}, from @noble/hashes ${found.version}; ${vectors.length} vectors pass, the slowest in ${slowest} ms here.`);
}
