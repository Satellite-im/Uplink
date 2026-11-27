#!/usr/bin/env node
/**
 * Uplink for Linux on gogho.st (Matt, 2026-11-20: "add support on the website for linux based systems and
 * downloads").
 *
 *   node tool/release-linux.mjs --glyph ~/Development/Apps/glyph [--run <id>] [--ref <branch>] [--keep-connection] [--again] [--no-p2p]
 *
 * A Mac cannot build the Linux app: .github/workflows/messaging-linux.yml does, on an Ubuntu runner, for the version in
 * pubspec.yaml (this starts it, unless --run names one that already ran). Its two packages are fetched with `gh` and
 * put beside the others in /opt/ghost-sms-release: ghost-messaging-linux.deb (Ubuntu, Debian and their family) and
 * ghost-messaging-linux-x64.tar.gz (any distribution), with linux.json saying the version, sizes and SHA-256s. The
 * site's Linux buttons read linux.json; the site's Caddy block names all three (tool/deploy-site.mjs --caddy).
 *
 * One login to the box (the same box code as tool/release-mac.mjs, from Ghost.md's checkout). Not signed: Linux asks
 * nothing of a package's signature for a download.
 */
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { requireNotes } from './lib/notes.mjs';
import { refLacksRelease } from './lib/built_ref.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
// The site's address since 2026-11-15 (tool/deploy-site.mjs); /opt/ghost-sms-* keep their names on the box.
const HOST_URL = 'https://gogho.st';
const RELEASE = '/opt/ghost-sms-release';
const BACKUPS = '/opt/ghost-sms-releases';
const DEB = 'ghost-messaging-linux.deb';
const TAR = 'ghost-messaging-linux-x64.tar.gz';
const FEED = 'linux.json';
const WORKFLOW = 'messaging-linux.yml';
const OUT = join(ROOT, 'build/release-linux');

const args = process.argv.slice(2);
const flag = (name) => {
  const at = args.indexOf(`--${name}`);
  return at < 0 ? undefined : args[at + 1];
};
const has = (name) => args.includes(`--${name}`);
const say = (line) => console.log(line);
const fail = (why) => {
  console.error(`x ${why}`);
  process.exit(1);
};
// Runs a command for what it prints, and stops the release if it fails.
const out = (cmd, cmdArgs) => {
  const r = spawnSync(cmd, cmdArgs, { encoding: 'utf8' });
  if (r.status !== 0) fail(`${cmd} ${cmdArgs.join(' ')} failed: ${(r.stderr || r.stdout || '').trim().slice(0, 400)}`);
  return r.stdout.trim();
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const pubspec = readFileSync(join(ROOT, 'pubspec.yaml'), 'utf8');
const [, versionName, versionCode] = pubspec.match(/^version:\s*([0-9.]+)\+(\d+)/m) ?? fail('No version in pubspec.yaml.');
requireNotes(ROOT, versionName, args, fail);

// What the site says is out now (linux.json), or null where there is nothing or it cannot be read.
async function liveRelease() {
  try {
    const r = await fetch(`${HOST_URL}/${FEED}?t=${Date.now()}`, { cache: 'no-store' });
    return r.ok ? await r.json() : null;
  } catch (_) {
    return null;
  }
}
{
  const now = await liveRelease();
  if (now && now.version === versionName && !has('again')) fail(`Uplink for Linux ${versionName} is already on the site (--again to send it again).`);
}

// The build: started here for this version, or one that already ran.
let run = flag('run');
if (!run) {
  const before = new Set(JSON.parse(out('gh', ['run', 'list', '--workflow', WORKFLOW, '--limit', '20', '--json', 'databaseId'])).map((r) => r.databaseId));
  say(`> Building Uplink for Linux ${versionName} (${versionCode}) on GitHub`);
  // --no-p2p: the runner leaves the direct network's core out (the workflow's own `p2p` input; the app then has no
  // direct route). Not said at all otherwise, so a workflow from before the core is asked nothing it doesn't know.
  // The runner builds what GitHub has at the branch, never what is here: refused unless that is this release
  // (tool/lib/built_ref.mjs: 0.12.24 and 0.12.25 were 0.12.23's code under their numbers).
  const ref = flag('ref') ?? 'main';
  const lacks = refLacksRelease(ROOT, ref);
  if (lacks) fail(`${lacks} Nothing was built.`);
  out('gh', ['workflow', 'run', WORKFLOW, '--ref', ref, '-f', `version=${versionName}`, '-f', `build=${versionCode}`, ...(has('no-p2p') ? ['-f', 'p2p=no'] : [])]);
  for (let i = 0; i < 30 && !run; i++) {
    await sleep(4000);
    const fresh = JSON.parse(out('gh', ['run', 'list', '--workflow', WORKFLOW, '--limit', '5', '--json', 'databaseId'])).find((r) => !before.has(r.databaseId));
    if (fresh) run = String(fresh.databaseId);
  }
  if (!run) fail('The build did not start on GitHub.');
}
say(`  run ${run}`);
for (;;) {
  const r = JSON.parse(out('gh', ['run', 'view', run, '--json', 'status,conclusion']));
  if (r.status === 'completed') {
    if (r.conclusion !== 'success') fail(`The Linux build ended ${r.conclusion}: gh run view ${run} --log-failed`);
    break;
  }
  await sleep(20000);
}
rmSync(OUT, { recursive: true, force: true });
mkdirSync(OUT, { recursive: true });
out('gh', ['run', 'download', run, '--dir', OUT]);
// The workflow names the .deb with its version; it is published under one name, so the site's link never changes.
const files = [];
(function find(dir) {
  for (const n of readdirSync(dir)) {
    const p = join(dir, n);
    if (statSync(p).isDirectory()) find(p);
    else files.push(p);
  }
})(OUT);
const debFound = files.find((p) => /ghost-messaging_.*_amd64\.deb$/.test(p));
const tarFound = files.find((p) => p.endsWith(TAR));
if (!debFound || !tarFound) fail(`No .deb and .tar.gz in run ${run}'s artifacts.`);
// A file as the feed lists it: the name it is served under, its size and its SHA-256.
const described = (path, url) => {
  const bytes = readFileSync(path);
  return { url, bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') };
};
const deb = described(debFound, DEB);
const tar = described(tarFound, TAR);
const info = { version: versionName, versionCode: Number(versionCode), ...deb, tar, build: new Date().toISOString(), run: Number(run) };
writeFileSync(join(OUT, FEED), JSON.stringify(info, null, 2) + '\n');
say(`ok ${DEB}: ${(deb.bytes / 1e6).toFixed(1)} MB; ${TAR}: ${(tar.bytes / 1e6).toFixed(1)} MB`);

// The box and its login are Ghost.md's: its checkout is found, and its own scripts open the connection.
const glyph = [flag('glyph'), process.env.GLYPH_ROOT, join(ROOT, '..'), join(homedir(), 'Development/Apps/glyph')]
  .filter(Boolean)
  .find((dir) => existsSync(join(dir, 'tauri/scripts/lib/box.mjs')) && existsSync(join(dir, 'scripts/lib/env.mjs')));
if (!glyph) fail('No Ghost.md checkout found for its box code (--glyph <path> or GLYPH_ROOT).');
const { BOX_ENV_KEYS, boxSshOptions, openBox } = await import(pathToFileURL(join(glyph, 'tauri/scripts/lib/box.mjs')).href);
const { loadEnv } = await import(pathToFileURL(join(glyph, 'scripts/lib/env.mjs')).href);
const box = openBox(loadEnv(BOX_ENV_KEYS), boxSshOptions({ connectTimeout: 20 }));
say('> Logging in to the box');
box.logIn();
const STAGE = '/tmp/ghost-messaging-linux-stage';
box.ssh(`rm -rf ${STAGE} && mkdir -p ${STAGE}`);
say(`> Uploading (${((deb.bytes + tar.bytes) / 1e6).toFixed(1)} MB)`);
box.rsync(['--progress'], debFound, `${STAGE}/${DEB}`);
box.rsync(['--progress'], tarFound, `${STAGE}/${TAR}`);
box.rsync([], join(OUT, FEED), `${STAGE}/${FEED}`);
say('> Publishing');
// The packages first, whole, by rename; linux.json last. The live three are kept outside the web root first.
box.ssh(`set -e
SUDO=; [ "$(id -u)" -eq 0 ] || SUDO=sudo
[ "$(sha256sum ${STAGE}/${DEB} | cut -d' ' -f1)" = "${deb.sha256}" ] || { echo "x the .deb arrived changed"; exit 1; }
[ "$(sha256sum ${STAGE}/${TAR} | cut -d' ' -f1)" = "${tar.sha256}" ] || { echo "x the .tar.gz arrived changed"; exit 1; }
stamp=$(date -u +%Y%m%d%H%M%S)
$SUDO mkdir -p ${RELEASE} ${BACKUPS}
if [ -f ${RELEASE}/${FEED} ]; then $SUDO mkdir -p ${BACKUPS}/linux-before-$stamp && $SUDO cp -p ${RELEASE}/${FEED} ${RELEASE}/${DEB} ${RELEASE}/${TAR} ${BACKUPS}/linux-before-$stamp/ 2>/dev/null || true; fi
for f in ${DEB} ${TAR} ${FEED}; do
  $SUDO install -m 644 -o root -g root ${STAGE}/$f ${RELEASE}/.$f.new
  $SUDO mv -f ${RELEASE}/.$f.new ${RELEASE}/$f
done
$SUDO chmod 755 ${RELEASE}
rm -rf ${STAGE}
echo "ok placed in ${RELEASE}"`);
const said = await liveRelease();
if (!has('keep-connection')) box.close();
if (said?.sha256 !== info.sha256) {
  say(`x ${HOST_URL}/${FEED} is not this release. It is in ${RELEASE} on the box; the site's Caddy block must name /${FEED}, /${DEB} and /${TAR} (node tool/deploy-site.mjs --caddy).`);
  process.exit(1);
}
const head = await fetch(`${HOST_URL}/${DEB}`, { method: 'HEAD' });
say(`ok live: ${HOST_URL}/${FEED} — Uplink for Linux ${info.version} (${info.versionCode}), .deb served at ${head.headers.get('content-length')} bytes (${deb.bytes} expected)`);

// The source, published as this release has it (tool/publish-source.mjs; Matt, 2026-11-15: "update the notes on claude
// so that each release runs this automatically"). The release is live either way: a failure here is said, not fatal.
if (!process.argv.includes('--no-source')) {
  say('> Publishing the source (github.com/InfamousVague/ghost-messaging)');
  const published = spawnSync('node', [join(ROOT, 'tool/publish-source.mjs')], { stdio: 'inherit' });
  if (published.status !== 0) say('x The source was not published; run node tool/publish-source.mjs');
}
