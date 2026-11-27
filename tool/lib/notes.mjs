/**
 * Release notes, required (Matt, 2026-11-19: "Implement a changelog that pops up ever time a new update is released
 * with release notes"): lib/changelog.dart must have an entry for the version being released, or the release stops
 * before building. The app shows the entry once after updating (lib/ui/whats_new.dart). `--no-notes` releases
 * without one, where that is asked for.
 */
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

/** The notes written for [version] in lib/changelog.dart under [root], one line each; null where there is no entry. */
export function notesFor(root, version) {
  const source = readFileSync(join(root, 'lib/changelog.dart'), 'utf8');
  const at = source.indexOf(`ReleaseNotes('${version}'`);
  if (at < 0) return null;
  const end = source.indexOf(']),', at);
  const body = source.slice(at, end < 0 ? undefined : end);
  return [...body.matchAll(/^\s+'((?:[^'\\]|\\.)*)',\s*$/gm)].map((m) => m[1].replace(/\\'/g, "'"));
}

/** Stops the release, saying what to do, where [version] has no notes and `--no-notes` was not given. */
export function requireNotes(root, version, args, fail) {
  if (args.includes('--no-notes')) return;
  const notes = notesFor(root, version);
  if (!notes || notes.length === 0) {
    fail(`No release notes for ${version}. Add ReleaseNotes('${version}', '<date>', [...]) at the top of lib/changelog.dart, a plain line for each thing people will notice (What's new shows it after the update), commit it, then release. --no-notes releases without them.`);
  }
  console.log(`ok release notes for ${version}: ${notes.length} line${notes.length === 1 ? '' : 's'}`);
}
