#!/usr/bin/env node
/**
 * Uplink's source, published (Matt, 2026-11-15: "I want to open source it for the privacy focused nature";
 * "once done publish the repo as a public repo on my github").
 *
 *   node tool/publish-source.mjs [--dry-run]
 *
 * The app is developed in Ghost.md's repository (messaging/); github.com/InfamousVague/ghost-messaging is its public
 * copy. Each release script runs this at its end (tool/release.mjs, release-mac.mjs, release-windows.mjs; Matt,
 * 2026-11-15: "update the notes on claude so that each release runs this automatically"). This copies messaging/
 * as committed at HEAD (never uncommitted work) into a checkout of the public repository and commits it
 * as one snapshot named for the version in pubspec.yaml: the public history is one commit a release, never the
 * private repository's own history (whose old commits were never written to be public).
 *
 * Also sends sidecar/gmessages to github.com/InfamousVague/ghost-gmessages-sidecar where it changed, since a release
 * that carries the sidecar must have its source published (the AGPL).
 */
import { spawnSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const dry = process.argv.includes('--dry-run');
const say = (line) => console.log(line);
const fail = (why) => {
  console.error(`x ${why}`);
  process.exit(1);
};
/** Runs a command and gives back what it printed, trimmed; stops everything if it fails. */
const run = (cmd, args, opts = {}) => {
  const r = spawnSync(cmd, args, { encoding: 'utf8', ...opts });
  if (r.status !== 0) fail(`${cmd} ${args.join(' ')} failed: ${(r.stderr || r.stdout || '').trim().slice(0, 400)}`);
  return (r.stdout || '').trim();
};

const version = (readFileSync(join(ROOT, 'pubspec.yaml'), 'utf8').match(/^version:\s*([0-9.]+)\+(\d+)/m) ?? fail('No version in pubspec.yaml.'))[1];

/** Mirrors [files] (relative to [from]) into the checkout at [to], removing what is no longer there. */
function mirror(from, files, to) {
  for (const name of readdirSync(to)) if (name !== '.git') rmSync(join(to, name), { recursive: true, force: true });
  for (const f of files) {
    const src = join(from, f);
    if (!existsSync(src)) continue; // tracked but deleted in the working tree
    mkdirSync(dirname(join(to, f)), { recursive: true });
    cpSync(src, join(to, f));
  }
}

/**
 * Makes the public [repo] hold exactly [files] of [from], as one commit named [message] pushed to its main. The
 * checkout is kept in build/public between runs. With nothing changed nothing is committed; a dry run only lists.
 */
function publish(repo, from, files, message) {
  const at = join(ROOT, 'build/public', repo.split('/')[1]);
  if (!existsSync(join(at, '.git'))) {
    mkdirSync(dirname(at), { recursive: true });
    run('gh', ['repo', 'clone', repo, at, '--', '--quiet']);
  }
  // A repository with nothing in it yet has nothing to bring down.
  if (spawnSync('git', ['-C', at, 'rev-parse', '--verify', '--quiet', 'HEAD']).status === 0) run('git', ['-C', at, 'pull', '--quiet', '--ff-only']);
  mirror(from, files, at);
  run('git', ['-C', at, 'add', '-A']);
  if (!run('git', ['-C', at, 'status', '--porcelain'])) {
    say(`ok ${repo}: nothing changed`);
    return;
  }
  if (dry) {
    say(`(dry run) ${repo} would change:\n${run('git', ['-C', at, 'status', '--short']).split('\n').slice(0, 30).join('\n')}`);
    run('git', ['-C', at, 'reset', '--quiet', '--hard']);
    return;
  }
  run('git', ['-C', at, 'commit', '--quiet', '-m', message]);
  run('git', ['-C', at, 'push', '--quiet', 'origin', 'HEAD:main']);
  say(`ok ${repo}: ${message}`);
}

// What is committed, not what the folder holds now: a release runs in a checkout that may have work in it not yet
// meant for anyone. messaging/ at HEAD, written out whole beside the checkouts.
const snapshot = join(ROOT, 'build/public/.snapshot');
rmSync(snapshot, { recursive: true, force: true });
mkdirSync(snapshot, { recursive: true });
const tar = spawnSync('git', ['archive', '--format=tar', 'HEAD', '.'], { cwd: ROOT, maxBuffer: 1 << 30 });
if (tar.status !== 0) fail(`git archive failed: ${tar.stderr}`);
const untar = spawnSync('tar', ['-x', '-C', snapshot], { input: tar.stdout });
if (untar.status !== 0) fail(`tar failed: ${untar.stderr}`);
/** The files committed at HEAD under [dir], by their paths from it. */
const listed = (dir) => run('git', ['ls-tree', '-r', '--name-only', '-z', 'HEAD', '.'], { cwd: dir }).split('\0').filter(Boolean);

// The whole app, as committed.
const tracked = listed(ROOT);
if (!tracked.includes('LICENSE')) fail('No LICENSE in messaging/: nothing is published without one.');
publish('InfamousVague/ghost-messaging', snapshot, tracked, `Uplink ${version}`);

// The sidecar on its own, for those who look for it there.
const sidecar = join(snapshot, 'sidecar/gmessages');
const sidecarFiles = listed(join(ROOT, 'sidecar/gmessages')).filter((f) => f !== 'SOURCE_URL');
publish('InfamousVague/ghost-gmessages-sidecar', sidecar, sidecarFiles, `As in Uplink ${version}`);
