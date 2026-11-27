#!/usr/bin/env node
/**
 * Uplink for Windows on ghost-sms.com (Matt, 2026-11-14: "Add a mac and windows build to ghost-sms.com").
 *
 *   node tool/release-windows.mjs --glyph ~/Development/Apps/glyph [--run <id>] [--keep-connection] [--again] [--no-p2p]
 *
 * A Mac cannot build the Windows app: .github/workflows/messaging-windows.yml does, on a Windows runner, for the
 * version in pubspec.yaml (this starts it, unless --run names one that already ran). Its installer is fetched with
 * `gh`, then put beside the APK and the Mac's zip in /opt/ghost-sms-release as ghost-messaging-setup.exe, with
 * windows.json saying its version, size and SHA-256. The site's Windows button reads windows.json.
 *
 * One login to the box (the same box code as tool/release-mac.mjs, from Ghost.md's checkout). The workflow signs the
 * app and its installer once the repository has the Azure Artifact Signing secrets (its header lists them); until
 * then the installer is unsigned and Windows asks before running it the first time.
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
const EXE = 'ghost-messaging-setup.exe';
const FEED = 'windows.json';
const WORKFLOW = 'messaging-windows.yml';
const OUT = join(ROOT, 'build/release-windows');

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

// What the site says is out now (windows.json), or null where there is nothing or it cannot be read.
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
  if (now && now.version === versionName && !has('again')) fail(`Uplink for Windows ${versionName} is already on the site (--again to send it again).`);
}

// The build: started here for this version, or one that already ran.
let run = flag('run');
if (!run) {
  const before = new Set(JSON.parse(out('gh', ['run', 'list', '--workflow', WORKFLOW, '--limit', '20', '--json', 'databaseId'])).map((r) => r.databaseId));
  say(`> Building Uplink for Windows ${versionName} (${versionCode}) on GitHub`);
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
    if (r.conclusion !== 'success') fail(`The Windows build ended ${r.conclusion}: gh run view ${run} --log-failed`);
    break;
  }
  await sleep(20000);
}
rmSync(OUT, { recursive: true, force: true });
mkdirSync(OUT, { recursive: true });
out('gh', ['run', 'download', run, '--dir', OUT]);
// The installer, wherever in the downloaded artifacts it lies.
const found = (function find(dir) {
  for (const n of readdirSync(dir)) {
    const p = join(dir, n);
    if (statSync(p).isDirectory()) {
      const f = find(p);
      if (f) return f;
    } else if (n === EXE) return p;
  }
  return null;
})(OUT);
if (!found) fail(`No ${EXE} in run ${run}'s artifacts.`);
const bytes = readFileSync(found);
const info = { version: versionName, versionCode: Number(versionCode), sha256: createHash('sha256').update(bytes).digest('hex'), bytes: bytes.length, url: EXE, build: new Date().toISOString(), run: Number(run) };
writeFileSync(join(OUT, FEED), JSON.stringify(info, null, 2) + '\n');
say(`ok ${EXE}: ${(info.bytes / 1e6).toFixed(1)} MB, sha256 ${info.sha256.slice(0, 16)}…`);

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
const STAGE = '/tmp/ghost-messaging-windows-stage';
box.ssh(`rm -rf ${STAGE} && mkdir -p ${STAGE}`);
say(`> Uploading (${(info.bytes / 1e6).toFixed(1)} MB)`);
box.rsync(['--progress'], found, `${STAGE}/${EXE}`);
box.rsync([], join(OUT, FEED), `${STAGE}/${FEED}`);
say('> Publishing');
// The installer first, whole, by rename; windows.json last. The live two are kept outside the web root first.
box.ssh(`set -e
SUDO=; [ "$(id -u)" -eq 0 ] || SUDO=sudo
[ "$(sha256sum ${STAGE}/${EXE} | cut -d' ' -f1)" = "${info.sha256}" ] || { echo "x the installer arrived changed"; exit 1; }
stamp=$(date -u +%Y%m%d%H%M%S)
$SUDO mkdir -p ${RELEASE} ${BACKUPS}
if [ -f ${RELEASE}/${FEED} ]; then $SUDO mkdir -p ${BACKUPS}/windows-before-$stamp && $SUDO cp -p ${RELEASE}/${FEED} ${RELEASE}/${EXE} ${BACKUPS}/windows-before-$stamp/; fi
$SUDO install -m 644 -o root -g root ${STAGE}/${EXE} ${RELEASE}/.${EXE}.new
$SUDO mv -f ${RELEASE}/.${EXE}.new ${RELEASE}/${EXE}
$SUDO install -m 644 -o root -g root ${STAGE}/${FEED} ${RELEASE}/.${FEED}.new
$SUDO mv -f ${RELEASE}/.${FEED}.new ${RELEASE}/${FEED}
$SUDO chmod 755 ${RELEASE}
rm -rf ${STAGE}
echo "ok placed in ${RELEASE}"`);
const said = await liveRelease();
if (!has('keep-connection')) box.close();
if (said?.sha256 !== info.sha256) {
  say(`x ${HOST_URL}/${FEED} is not this release. It is in ${RELEASE} on the box; the site's Caddy block must name /${FEED} and /${EXE} (node tool/deploy-site.mjs --caddy).`);
  process.exit(1);
}
const head = await fetch(`${HOST_URL}/${EXE}`, { method: 'HEAD' });
say(`ok live: ${HOST_URL}/${FEED} — Uplink for Windows ${info.version} (${info.versionCode}), installer served at ${head.headers.get('content-length')} bytes (${info.bytes} expected)`);

// The source, published as this release has it (tool/publish-source.mjs; Matt, 2026-11-15: "update the notes on claude
// so that each release runs this automatically"). The release is live either way: a failure here is said, not fatal.
if (!process.argv.includes('--no-source')) {
  say('> Publishing the source (github.com/InfamousVague/ghost-messaging and github.com/Satellite-im/Uplink)');
  const published = spawnSync('node', [join(ROOT, 'tool/publish-source.mjs')], { stdio: 'inherit' });
  if (published.status !== 0) say('x The source was not published; run node tool/publish-source.mjs');
}
