#!/usr/bin/env node
/**
 * Uplink for Linux on gogho.st (Matt, 2026-11-20: "add support on the website for linux based systems and
 * downloads").
 *
 *   node tool/release-linux.mjs [--run <id>] [--ref <branch>] [--keep-connection] [--again] [--no-p2p] [--on uplink|glyph]
 *
 * A Mac cannot build the Linux app: an Ubuntu runner on GitHub does, for the version in pubspec.yaml (this starts it,
 * unless --run names one that already ran), in Satellite-im/Uplink, the app's own repository
 * (.github/workflows/linux.yml, published there with the source; tool/lib/runners.mjs). `--on glyph` builds it where
 * it was built before, in the repository the app is developed in (its messaging-linux.yml, at --ref or its main),
 * for as long as that workflow is kept. Its two packages are fetched with `gh` and
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
import { RUNS_IN, finished, runnerFor, started } from './lib/runners.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
// The site's address since 2026-11-15 (tool/deploy-site.mjs); /opt/ghost-sms-* keep their names on the box.
const HOST_URL = 'https://gogho.st';
const RELEASE = '/opt/ghost-sms-release';
const BACKUPS = '/opt/ghost-sms-releases';
const DEB = 'ghost-messaging-linux.deb';
const TAR = 'ghost-messaging-linux-x64.tar.gz';
const FEED = 'linux.json';
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

const whereBuilt = () => RUNS_IN;

// Where it is built: where tool/lib/runners.mjs says a release builds for now, unless --on uplink or --on glyph says.
const on = flag('on') ?? whereBuilt();
if (on !== 'uplink' && on !== 'glyph') fail(`--on ${on}: uplink (Satellite-im/Uplink) or glyph (where it was built before).`);

// The build: started here for this version, or one that already ran (--run, with --on where it ran elsewhere).
let run = flag('run');
let built = { run, repo: runnerFor(on, 'linux').repo, sha: null };
if (!run) {
  say(`> Building Uplink for Linux ${versionName} (${versionCode}) on GitHub, in ${built.repo}`);
  // The runner builds what its repository holds, never what is here: Satellite-im/Uplink's main is brought up to this
  // release first and the build held to that commit; the old repository's main is refused unless it is this release
  // (tool/lib/built_ref.mjs: 0.12.24 and 0.12.25 were 0.12.23's code under their numbers).
  built = await started({ root: ROOT, on, name: 'linux', versionName, versionCode, noP2p: has('no-p2p'), ref: flag('ref'), out, say, fail, sleep });
  run = built.run;
}
say(`  run ${run}`);
await finished({ run, repo: built.repo, sha: built.sha, what: 'Linux', out, fail, sleep });
rmSync(OUT, { recursive: true, force: true });
mkdirSync(OUT, { recursive: true });
out('gh', ['run', 'download', run, '--repo', built.repo, '--dir', OUT]);
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

// The box and its login: tool/lib/box.mjs, from ~/.config/uplink/release.env.
const { BOX_ENV_KEYS, boxSshOptions, openBox } = await import('./lib/box.mjs');
const { loadEnv } = await import('./lib/box.mjs');
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
  say('> Publishing the source (github.com/InfamousVague/ghost-messaging and github.com/Satellite-im/Uplink)');
  const published = spawnSync('node', [join(ROOT, 'tool/publish-source.mjs')], { stdio: 'inherit' });
  if (published.status !== 0) say('x The source was not published; run node tool/publish-source.mjs');
}
// The release on GitHub (tool/release-github.mjs; Matt, 2026-11-27, asked whether every release should publish one:
// "Yes, every release"): this version's installers at github.com/Satellite-im/Uplink/releases as far as they are out,
// a draft until every platform is. After the source, whose commit the release's tag stands on. Said, not fatal.
if (!process.argv.includes('--no-github')) {
  say('> The release on GitHub (github.com/Satellite-im/Uplink/releases)');
  const onGithub = spawnSync('node', [join(ROOT, 'tool/release-github.mjs')], { stdio: 'inherit' });
  if (onGithub.status !== 0) say('x The release on GitHub was not made or filled; run node tool/release-github.mjs');
}
