#!/usr/bin/env node
/**
 * Makes the admin page's sign-in (Matt, 2026-11-19: "a simple admin page for me to login to in order to issue souls with
 * a pre generated username and password"): a username and a long random password, and the password as the relay keeps
 * it (relay/lib/handles.dart Handles.adminHashOf: SHA-256 over "ghost-admin v1|salt|password", then again 99 999 times).
 *
 *   node tool/admin-password.mjs <relay env file> <where to write the sign-in>
 *
 * Writes GHOST_ADMIN_USER and GHOST_ADMIN_HASH into the relay's env file (in place of any before), and the username
 * and password, readable by this Mac's user alone, to the second file. The password itself goes nowhere else: the relay
 * gets only its hash (node tool/deploy-relay.mjs --env <relay env file>).
 */
import { createHash, randomBytes } from 'node:crypto';
import { chmodSync, existsSync, readFileSync, writeFileSync } from 'node:fs';

/** The password as the relay keeps it, in hex: 100 000 rounds of SHA-256 in all, the first over the salted text. */
export function adminHash(salt, pass) {
  let h = createHash('sha256').update(`ghost-admin v1|${salt}|${pass}`, 'utf8').digest();
  for (let i = 1; i < 100000; i++) h = createHash('sha256').update(h).digest();
  return h.toString('hex');
}

// Only when run as a script: imported, this file gives adminHash and writes nothing.
const [envFile, outFile] = process.argv.slice(2);
if (process.argv[1] && process.argv[1].endsWith('admin-password.mjs')) {
  if (!envFile || !outFile) {
    console.error('usage: node tool/admin-password.mjs <relay env file> <where to write the sign-in>');
    process.exit(2);
  }
  const words = ['wisp', 'shade', 'lantern', 'hollow', 'ember', 'veil', 'echo', 'mist'];
  const user = `${words[randomBytes(1)[0] % words.length]}-keeper-${randomBytes(2).toString('hex')}`;
  const pass = randomBytes(18).toString('base64url');
  const salt = randomBytes(16).toString('hex');
  // salt:hash (the relay's env file takes letters, digits and a few marks: no "$").
  const hash = `${salt}:${adminHash(salt, pass)}`;
  const before = existsSync(envFile) ? readFileSync(envFile, 'utf8') : '';
  const kept = before.split('\n').filter((l) => l.trim() && !/^GHOST_ADMIN_(USER|HASH)=/.test(l));
  writeFileSync(envFile, [...kept, `GHOST_ADMIN_USER=${user}`, `GHOST_ADMIN_HASH=${hash}`, ''].join('\n'), { mode: 0o600 });
  chmodSync(envFile, 0o600);
  writeFileSync(outFile, `Uplink admin page (Settings › Developer › Admin, signed in as @matt)\nusername: ${user}\npassword: ${pass}\n`, { mode: 0o600 });
  chmodSync(outFile, 0o600);
  console.log(`ok the sign-in is in ${outFile} (this Mac's user alone may read it); ${envFile} has GHOST_ADMIN_USER and GHOST_ADMIN_HASH`);
  console.log(`  next: node tool/deploy-relay.mjs --env ${envFile}`);
}
