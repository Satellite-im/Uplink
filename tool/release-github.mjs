#!/usr/bin/env node
/**
 * Uplink's release on GitHub: each version's installers at github.com/Satellite-im/Uplink/releases (Matt, 2026-11-27:
 * "also tag a release on github with the latest assets since the other release is several years old"; asked whether
 * every release should publish one, "Yes, every release").
 *
 *   node tool/release-github.mjs              this version (pubspec.yaml), as far as it is out
 *   node tool/release-github.mjs --dry-run    says what it would do; nothing is made, sent or fetched but the feeds
 *   node tool/release-github.mjs --publish    publishes it though a platform is not out at this version
 *   node tool/release-github.mjs --draft      fills it and leaves it a draft, whatever is out
 *   node tool/release-github.mjs --version 0.12.51 --tag v0.12.51-check    another version, another tag (for a try)
 *
 * Each release script runs this at its end, after the source is published (tool/release.mjs, release-mac.mjs,
 * release-windows.mjs, release-linux.mjs; `--no-github` there leaves it out). The release is live either way: a failure
 * here is said, never fatal.
 *
 * WHAT IS OUT is what the site says is out: its four feeds (apk.json, mac.json, windows.json, linux.json), which name
 * each file with its size and SHA-256. A platform whose feed is at this version has its file put on the release,
 * under a name that says Uplink (the site's own files keep the names installed copies ask for). The file is the one
 * the site serves: the copy this checkout built where it is that very file (same size, same hash), else fetched from
 * the site, and in both cases checked against the feed before it is sent. SHA256SUMS.txt lists them.
 *
 * A RELEASE IS A DRAFT UNTIL EVERY PLATFORM IS OUT at this version. The Mac's script runs first and makes the draft
 * with the disk image; the phone's, Windows' and Linux's each add theirs; the one that finds all four out publishes it
 * and marks it the latest. Nobody is told of a release with files missing, and a draft is seen by the repository's
 * own people alone. A release of fewer platforms stays a draft unless --publish is given. Run again, it adds what is
 * missing and nothing else; a release already published keeps its words as they are.
 *
 * The tag is `v` and the version, on that repository's main, which tool/publish-source.mjs has just brought up to this
 * release's source. The app that was in that repository before tagged its releases with bare numbers (1.0.5): the `v`
 * keeps the two apart.
 */
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { copyFileSync, createReadStream, existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { notesFor } from './lib/notes.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const REPO = 'Satellite-im/Uplink';
// Where the feeds and the files are: the address installed copies update from.
const SITE = 'https://gogho.st';
// The address the release's words send a reader to.
const PAGE = 'https://satellite.im';

const args = process.argv.slice(2);
const has = (name) => args.includes(`--${name}`);
const flag = (name) => {
  const at = args.indexOf(`--${name}`);
  return at >= 0 && at + 1 < args.length ? args[at + 1] : undefined;
};
const dry = has('dry-run');
const say = (line) => console.log(line);
const fail = (why) => {
  console.error(`x release-github: ${why}`);
  process.exit(1);
};

const version = flag('version') ?? (readFileSync(join(ROOT, 'pubspec.yaml'), 'utf8').match(/^version:\s*([0-9.]+)\+\d+/m) ?? fail('No version in pubspec.yaml.'))[1];
if (!/^\d+\.\d+\.\d+$/.test(version)) fail(`"${version}" is not a version.`);
const tag = flag('tag') ?? `v${version}`;
if (!/^[A-Za-z0-9._-]+$/.test(tag)) fail(`"${tag}" is not a tag.`);

/** What a feed says of one file: where it is on the site, how long it is and its SHA-256. */
const said = (d) => ({ url: String(d.url), sha256: String(d.sha256), bytes: Number(d.bytes) });
/**
 * Each platform: its feed, the files the feed names (as the release names them, and the folder of this checkout its
 * release script leaves them in), and the line of the release's table for them.
 */
const PLATFORMS = [
  {
    on: 'Android',
    feed: 'apk.json',
    files: (d) => [{ name: `Uplink-${version}-android.apk`, near: 'build/release', ...said(d) }],
    how: ([apk]) => `\`${apk}\`. Open it on your phone, and allow your browser to install apps if Android asks.`,
  },
  {
    on: 'Mac',
    feed: 'mac.json',
    // The disk image is what a person downloads; the zip beside it is what an installed copy updates itself from.
    files: (d) => (d.dmg ? [{ name: `Uplink-${version}-mac.dmg`, near: 'build/release-mac', ...said(d.dmg) }] : []),
    how: ([dmg]) => `\`${dmg}\`. Open it and drag Uplink to Applications. Signed, and checked by Apple.`,
  },
  {
    on: 'Windows',
    feed: 'windows.json',
    files: (d) => [{ name: `Uplink-${version}-windows-setup.exe`, near: 'build/release-windows', ...said(d) }],
    how: ([exe]) => `\`${exe}\`. Run it, then open Uplink from the Start menu.`,
  },
  {
    on: 'Linux',
    feed: 'linux.json',
    files: (d) => [
      { name: `Uplink-${version}-linux-x64.deb`, near: 'build/release-linux', ...said(d) },
      ...(d.tar ? [{ name: `Uplink-${version}-linux-x64.tar.gz`, near: 'build/release-linux', ...said(d.tar) }] : []),
    ],
    how: ([deb, tar]) => `\`${deb}\` for Ubuntu, Debian and their family${tar ? `, or \`${tar}\` for any other: unpack it and run \`ghost-messaging\`` : ''}.`,
  },
];

/** A feed as the site gives it now, or null where it gives none. */
async function feed(name) {
  try {
    const got = await fetch(`${SITE}/${name}`, { cache: 'no-store', signal: AbortSignal.timeout(20000) });
    return got.ok ? await got.json() : null;
  } catch {
    return null;
  }
}

/** The SHA-256 of the file at [path], in hex. */
const hashOf = (path) =>
  new Promise((done, failed) => {
    const hash = createHash('sha256');
    createReadStream(path).on('data', (piece) => hash.update(piece)).on('end', () => done(hash.digest('hex'))).on('error', failed);
  });

/** Every file under [dir] that is [bytes] long: the release scripts keep theirs a folder or two down. */
function ofLength(dir, bytes, depth = 3) {
  if (!existsSync(dir) || depth < 0) return [];
  const found = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) found.push(...ofLength(path, bytes, depth - 1));
    else if (entry.isFile() && statSync(path).size === bytes) found.push(path);
  }
  return found;
}

/**
 * [file] as the feed describes it, at a path named as the release names it, in [work]: this checkout's own copy where
 * it is that very file, else the site's. Stops everything where what it holds is not what the feed says.
 */
async function held(file, work) {
  const to = join(work, file.name);
  for (const path of ofLength(join(ROOT, file.near), file.bytes)) {
    if ((await hashOf(path)) !== file.sha256) continue;
    copyFileSync(path, to);
    say(`  ${file.name}: this checkout's own copy`);
    return to;
  }
  const got = spawnSync('curl', ['-s', '--fail', '--max-time', '1800', '-o', to, `${SITE}/${file.url}`], { stdio: 'inherit' });
  if (got.status !== 0) fail(`${SITE}/${file.url} could not be fetched.`);
  if (statSync(to).size !== file.bytes || (await hashOf(to)) !== file.sha256) fail(`${SITE}/${file.url} is not the file its feed describes (${file.bytes} bytes, ${file.sha256.slice(0, 16)}…).`);
  say(`  ${file.name}: from ${SITE}/${file.url}`);
  return to;
}

const gh = (a) => spawnSync('gh', a, { encoding: 'utf8', maxBuffer: 1 << 26 });
/** Runs gh and stops everything where it fails. */
const must = (a) => {
  const r = gh(a);
  if (r.status !== 0) fail(`gh ${a.slice(0, 4).join(' ')} failed: ${(r.stderr || r.stdout || '').trim().slice(0, 400)}`);
  return r.stdout.trim();
};

// --- what is out ------------------------------------------------------------------------------------------------------

const out = [];
for (const platform of PLATFORMS) {
  const d = await feed(platform.feed);
  const list = d && d.version === version ? platform.files(d) : [];
  if (list.length) out.push({ ...platform, list });
}
const wanted = out.flatMap((p) => p.list);
for (const f of wanted) if (!/^[0-9a-f]{64}$/.test(f.sha256) || !(f.bytes > 0) || !/^[A-Za-z0-9._-]+$/.test(f.url)) fail(`The feed's account of ${f.name} is not whole.`);
const whole = out.length === PLATFORMS.length;
say(`> Uplink ${version} on GitHub (${REPO}, ${tag}): out on ${out.length ? out.map((p) => p.on).join(', ') : 'no platform yet'}`);
if (!wanted.length) {
  say(`ok nothing is out at ${version} yet, so there is nothing to put there.`);
  process.exit(0);
}

const sums = `${[...wanted].sort((a, b) => a.name.localeCompare(b.name)).map((f) => `${f.sha256}  ${f.name}`).join('\n')}\n`;
const SUMS = 'SHA256SUMS.txt';

/** The release's words: what is new, the files as far as they are out, and their hashes. */
function words() {
  const notes = notesFor(ROOT, version) ?? [];
  return [
    `The new Uplink: high-quality text, voice and video in one app, for Android, Mac, Windows, Linux and the browser. The [README](https://github.com/${REPO}#readme) says what it does and how to start.`,
    '',
    ...(notes.length ? [`## What's new in ${version}`, '', ...notes.map((n) => `- ${n}`), ''] : []),
    '## Downloads',
    '',
    '| On | File |',
    '| --- | --- |',
    ...out.map((p) => `| **${p.on}** | ${p.how(p.list.map((f) => f.name))} |`),
    '',
    `These are the same files as at [satellite.im](${PAGE}/), where the app also runs in a browser with nothing to install: [satellite.im/app](${PAGE}/app/). Once installed, Uplink keeps itself up to date, so there is no need to come back here for the next version.`,
    '',
    '## SHA-256',
    '',
    '```',
    sums.trimEnd(),
    '```',
    '',
  ].join('\n');
}

// --- the release as it stands ------------------------------------------------------------------------------------------

const seen = gh(['release', 'view', tag, '--repo', REPO, '--json', 'isDraft,assets,url']);
if (seen.status !== 0 && !/release not found|not found/i.test(seen.stderr || '')) fail(`gh release view ${tag} failed: ${(seen.stderr || '').trim().slice(0, 300)}`);
let release = seen.status === 0 ? JSON.parse(seen.stdout) : null;
const there = (name, bytes) => (release?.assets ?? []).some((a) => a.name === name && a.size === bytes);
const missing = wanted.filter((f) => !there(f.name, f.bytes));
const sumsStale = !there(SUMS, Buffer.byteLength(sums)) || missing.length > 0;
const publish = !has('draft') && (whole || has('publish'));

if (dry) {
  say(release ? `(dry run) ${tag} is there, ${release.isDraft ? 'a draft' : 'published'}, with ${release.assets.length} file${release.assets.length === 1 ? '' : 's'}.` : `(dry run) ${tag} would be made, a draft at first.`);
  say(missing.length ? `(dry run) would add: ${missing.map((f) => f.name).join(', ')}${sumsStale ? `, ${SUMS}` : ''}` : `(dry run) every file that is out is on it${sumsStale ? `; ${SUMS} would be written again` : ''}.`);
  if (!release || release.isDraft) say(publish ? '(dry run) and it would be published, as the latest.' : `(dry run) and it would stay a draft: ${has('draft') ? '--draft was given' : `not out yet on ${PLATFORMS.filter((p) => !out.some((o) => o.on === p.on)).map((p) => p.on).join(', ')}`}.`);
  process.exit(0);
}

const work = mkdtempSync(join(tmpdir(), 'uplink-release-'));
try {
  if (!release) {
    writeFileSync(join(work, 'words.md'), words());
    must(['release', 'create', tag, '--repo', REPO, '--target', 'main', '--title', `Uplink ${version}`, '--notes-file', join(work, 'words.md'), '--draft']);
    release = { isDraft: true, assets: [] };
    say(`ok ${tag} made, a draft`);
  }
  if (missing.length || sumsStale) {
    const files = [];
    for (const f of missing) files.push(await held(f, work));
    writeFileSync(join(work, SUMS), sums);
    // --clobber: a file of the same name and another length is a build of this version made again, and the site's is the one.
    must(['release', 'upload', tag, '--repo', REPO, '--clobber', ...files, join(work, SUMS)]);
    say(`ok ${tag}: ${missing.length ? `added ${missing.map((f) => f.name).join(', ')}` : `${SUMS} written again`}`);
  } else {
    say(`ok ${tag}: every file that is out is on it already`);
  }
  if (release.isDraft) {
    // A draft's words follow what is on it; a published release's are left as they were written.
    writeFileSync(join(work, 'words.md'), words());
    must(['release', 'edit', tag, '--repo', REPO, '--notes-file', join(work, 'words.md')]);
    if (publish) {
      must(['release', 'edit', tag, '--repo', REPO, '--draft=false', '--latest']);
      say(`ok ${tag} published, as the latest: https://github.com/${REPO}/releases/tag/${tag}`);
    } else {
      say(`  ${tag} stays a draft: ${has('draft') ? '--draft was given' : `not out yet on ${PLATFORMS.filter((p) => !out.some((o) => o.on === p.on)).map((p) => p.on).join(', ')} (--publish publishes it as it is)`}.`);
    }
  }
} finally {
  rmSync(work, { recursive: true, force: true });
}
