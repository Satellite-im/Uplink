// The browser's roster check (site/join/voice.js) against rosters the app signed (test/roster_cross_test.dart):
// the good ones believed, the forged and the altered not.
//   flutter test test/roster_cross_test.dart && node tool/voicebench/roster_check.mjs
import { readFileSync } from 'node:fs';
import { Roster } from '../../site/join/voice.js';
import { createHash } from 'node:crypto';

const all = JSON.parse(readFileSync(new URL('../../build/rosters.json', import.meta.url)));
const ownerId = createHash('sha256').update(Buffer.from(all.owner, 'hex')).digest('hex').slice(0, 32);
let failed = 0;
for (const [kind, want] of [['good', true], ['bad', false]]) {
  for (const j of all[kind]) {
    const r = new Roster(j, all.owner, ownerId);
    const got = await r.trusted();
    console.log(`${got === want ? 'ok' : 'FAIL'}: ${kind} roster v${j.v} by ${String(j.by).slice(0, 6)} ${got ? 'believed' : 'refused'}`);
    if (got !== want) failed++;
  }
}
const r = new Roster(all.good[0], all.owner, ownerId);
await r.trusted();
const muted = !r.can(all.other, 'speak') && r.roleOf(all.other).id === 'moderator';
console.log(`${muted ? 'ok' : 'FAIL'}: the muted moderator can't speak`);
if (!muted) failed++;
process.exit(failed ? 1 : 0);
