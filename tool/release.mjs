#!/usr/bin/env node
/**
 * Builds, checks and publishes an Uplink release to the box (the server Ghost.md and Ghost Keyboard deploy
 * to), where installed copies find it and update themselves (android/.../Updater.kt). Ghost Keyboard's
 * tool/release.mjs, for this app (Matt, 2026-11-13: "add auto update and serve it over ghost-sms.com I'll point the
 * domain to the same server ghost kbd uses").
 *
 *   node tool/release.mjs [--glyph ~/path/to/glyph] [--version 0.4.0] [--no-deploy] [--keep-connection] [--again] [--no-p2p] [--no-web]
 *
 * Once the release is live, the web client is built and published at gogho.st/app with it (tool/release-web.mjs;
 * GMFB-30), so it follows the app's releases; --no-web leaves it as it is.
 *
 * Put in /opt/ghost-sms-release, which ghost-sms.com's Caddy block (tool/deploy-site.mjs --caddy) serves at:
 *
 *   https://gogho.st/apk.json             { version, versionCode, sha256, bytes, url, build }: what an installed app reads
 *   https://gogho.st/ghost-messaging.apk  the release, signed with the release key; the site's download
 *
 * RUN tool/deploy-site.mjs --caddy ONCE FIRST, so the domain has its block; a release before that is placed but
 * not served, and this says so.
 *
 * THE CREDENTIALS ARE GHOST.MD'S. Nothing is copied here: the box's address, account and password are read from
 * Ghost.md's own .env (tauri/.env: AFM_DEPLOY_HOST, AFM_DEPLOY_USER, AFM_DEPLOY_PASS) by Ghost.md's own loader, and the
 * box is reached through Ghost.md's box.mjs, so this spends ONE login on the shared, multiplexed connection exactly as
 * Ghost.md's deploys do (the box locks an account out after a few logins in a short window). This app lives in
 * Ghost.md's repository (messaging/), so the checkout is the folder above; --glyph or $GLYPH_ROOT say otherwise.
 *
 * THE RELEASE KEY is ~/.config/ghostmessaging/ (signing.properties and release.keystore), made here the first time.
 * Android installs an update only over the same certificate, so losing it means everyone reinstalls: back it up. The
 * certificate's SHA-256 is pinned in ~/.config/ghostmessaging/cert.sha256 by the first release, and a build signed by
 * anything else (the debug key included) is refused. A copy installed from a build made without this key (the first
 * ones, built in a cloud session) is replaced once by the release, and updates itself from then on.
 *
 * The version code is one above the live release's, so it always rises; the version name is pubspec.yaml's unless
 * --version says otherwise.
 */
import { spawnSync } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { chmodSync, copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { telegramDefines } from './telegram-defines.mjs';
import { requireNotes } from './lib/notes.mjs';
import { requireGuards } from './lib/guards.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
// The site's address since 2026-11-15 (tool/deploy-site.mjs); /opt/ghost-sms-* keep their names on the box.
const HOST_URL = 'https://gogho.st';
const RELEASE = '/opt/ghost-sms-release';
const BACKUPS = '/opt/ghost-sms-releases';
const APK = 'ghost-messaging.apk';
const PACKAGE = 'com.infamousvague.ghostmessaging';
const CONFIG = join(homedir(), '.config', 'ghostmessaging');

const args = process.argv.slice(2);
const flag = (name) => {
  const at = args.indexOf(`--${name}`);
  return at < 0 ? undefined : args[at + 1];
};
const deploy = !args.includes('--no-deploy');
const keepConnection = args.includes('--keep-connection');

const say = (line) => console.log(line);
const fail = (why) => {
  console.error(`x ${why}`);
  process.exit(1);
};
// Runs a command with its output shown, and stops the release if it fails.
const run = (cmd, cmdArgs, options = {}) => {
  const result = spawnSync(cmd, cmdArgs, { stdio: 'inherit', ...options });
  if (result.error) fail(`${cmd} could not run: ${result.error.message}`);
  if (result.status !== 0) fail(`${cmd} ${cmdArgs.join(' ')} failed (${result.status}).`);
  return result;
};
// Runs a command for what it prints, and stops the release if it fails.
const capture = (cmd, cmdArgs) => {
  const result = spawnSync(cmd, cmdArgs, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (result.error) fail(`${cmd} could not run: ${result.error.message}`);
  if (result.status !== 0) fail(`${cmd} failed: ${result.stderr || result.stdout}`);
  return result.stdout;
};

// --- Ghost.md, for the box and its credentials ----------------------------------------------------------------------

// The Ghost.md checkout, known by two of its scripts: --glyph, GLYPH_ROOT, beside this repository, or the usual
// folders under the home directory.
function findGlyph() {
  const candidates = [
    flag('glyph'),
    process.env.GLYPH_ROOT,
    join(ROOT, '..'),
    join(ROOT, '..', 'glyph'),
    join(ROOT, '..', 'Glyph'),
    ...['Projects', 'Developer', 'dev', 'code', 'src', 'GitHub', 'Documents/GitHub', 'repos', ''].map((d) => join(homedir(), d, 'glyph')),
  ].filter(Boolean);
  for (const dir of candidates) {
    if (existsSync(join(dir, 'tauri', 'scripts', 'lib', 'box.mjs')) && existsSync(join(dir, 'scripts', 'lib', 'env.mjs'))) return resolve(dir);
  }
  fail(`Could not find the Ghost.md checkout (looked in ${candidates.join(', ')}). Pass --glyph <path> or set GLYPH_ROOT.`);
}

// --- the Android SDK's tools --------------------------------------------------------------------------------------

const sdk = process.env.ANDROID_HOME || process.env.ANDROID_SDK_ROOT || join(homedir(), 'Library/Android/sdk');
// The path of a tool in the newest build-tools the SDK has.
function buildTool(name) {
  const tools = join(sdk, 'build-tools');
  const newest = existsSync(tools) ? readdirSync(tools).sort((a, b) => a.localeCompare(b, undefined, { numeric: true })).pop() : null;
  if (!newest) fail(`No Android build-tools under ${tools}: set ANDROID_HOME.`);
  return join(tools, newest, name);
}

// Java's keytool: JAVA_HOME's, Android Studio's, the system Java's, or whatever the PATH has.
function keytool() {
  const candidates = [
    process.env.JAVA_HOME && join(process.env.JAVA_HOME, 'bin', 'keytool'),
    '/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/keytool',
    '/Applications/Android Studio.app/Contents/jre/Contents/Home/bin/keytool',
  ].filter(Boolean);
  for (const path of candidates) if (existsSync(path)) return path;
  const javaHome = spawnSync('/usr/libexec/java_home', [], { encoding: 'utf8' });
  if (javaHome.status === 0 && existsSync(join(javaHome.stdout.trim(), 'bin', 'keytool'))) return join(javaHome.stdout.trim(), 'bin', 'keytool');
  return 'keytool';
}

// --- the release key ----------------------------------------------------------------------------------------------

// Makes the release keystore and its signing.properties the first time, readable by this user only. Every later
// release is signed with the same key, which is what lets a phone install it over the one before.
function ensureSigningKey() {
  const props = join(CONFIG, 'signing.properties');
  if (existsSync(props)) return;
  say('> No release key yet: making one in ~/.config/ghostmessaging (back this folder up)');
  mkdirSync(CONFIG, { recursive: true, mode: 0o700 });
  const store = join(CONFIG, 'release.keystore');
  const password = randomBytes(24).toString('hex');
  run(keytool(), [
    '-genkeypair', '-noprompt',
    '-keystore', store, '-storetype', 'PKCS12',
    '-alias', 'ghostmessaging', '-keyalg', 'RSA', '-keysize', '4096', '-validity', '36500',
    '-dname', 'CN=Ghost Messaging, O=InfamousVague',
    '-storepass', password, '-keypass', password,
  ]);
  writeFileSync(props, `storeFile=${store}\nstorePassword=${password}\nkeyAlias=ghostmessaging\nkeyPassword=${password}\n`, { mode: 0o600 });
  chmodSync(props, 0o600);
  chmodSync(store, 0o600);
}

// --- versions -----------------------------------------------------------------------------------------------------

// What the site says is out now (apk.json), or null where nothing has been released yet.
async function liveRelease() {
  try {
    const res = await fetch(`${HOST_URL}/apk.json?t=${Date.now()}`, { cache: 'no-store' });
    if (res.status === 404) return null;
    if (!res.ok) fail(`${HOST_URL}/apk.json answered ${res.status}.`);
    return await res.json();
  } catch (e) {
    fail(`Could not read the live release: ${e.message}`);
  }
}

// pubspec.yaml's `version: name+build`; the build is 1 where it is left off.
function pubspecVersion() {
  const match = /^version:\s*([0-9]+\.[0-9]+\.[0-9]+)(?:\+([0-9]+))?/m.exec(readFileSync(join(ROOT, 'pubspec.yaml'), 'utf8'));
  if (!match) fail('pubspec.yaml has no version.');
  return { name: match[1], build: Number(match[2] ?? 1) };
}

// --- the release --------------------------------------------------------------------------------------------------

const glyph = deploy ? findGlyph() : null;
if (glyph) say(`ok Ghost.md at ${glyph} (the box's credentials)`);

ensureSigningKey();

const live = await liveRelease();
const pub = pubspecVersion();
const versionName = flag('version') ?? pub.name;
requireNotes(ROOT, versionName, args, fail);
const versionCode = Math.max((live?.versionCode ?? 0) + 1, pub.build);
// A version that is live already is not published a second time (tool/release-mac.mjs says why): the same name
// live means someone has released it since this was started. --again says it is meant.
if (deploy && live && live.version === versionName && !args.includes('--again')) {
  fail(`${versionName} is live already (code ${live.versionCode}, published ${live.build ?? 'earlier'}): someone has released it. Nothing was built or sent. If it really is to go out again under the same name, pass --again.`);
}
// The guard tests (tool/lib/guards.mjs): what the source must keep for every build, read before one is made.
requireGuards(ROOT, fail);
say(`> Building Uplink ${versionName} (code ${versionCode}; live is ${live ? `${live.version} (${live.versionCode})` : 'nothing yet'})`);

// The Google Messages sidecar for the phone (sidecar/gmessages, AGPL-3.0; android GmWeb.kt), built fresh into
// jniLibs, only once its source is public (sidecar/gmessages/SOURCE_URL), as the computers' are.
if (existsSync(join(ROOT, 'sidecar/gmessages/SOURCE_URL'))) {
  say('> Building the Google Messages sidecar for the phone');
  run('sh', [join(ROOT, 'tool/build-gmsidecar.sh'), 'android'], { cwd: ROOT });
}
// The Signal helper for the phone (sidecar/signal, AGPL-3.0; lib/inbox/signal.dart) with Signal's libsignal and the
// C++ library it needs, built into jniLibs (Matt, 2026-11-16: "Add it to a release it's okay as long as our app bundle
// stays under 200mb"); its source is public with the app's (sidecar/signal/SOURCE_URL).
if (existsSync(join(ROOT, 'sidecar/signal/SOURCE_URL'))) {
  say('> Building the Signal helper for the phone');
  run('sh', [join(ROOT, 'tool/build-signalsidecar.sh'), 'android', '--ship'], { cwd: ROOT });
}
// The WhatsApp helper for the phone (sidecar/whatsapp, on whatsmeow, MPL-2.0; lib/inbox/whatsapp.dart), into jniLibs.
if (existsSync(join(ROOT, 'sidecar/whatsapp/SOURCE_URL'))) {
  say('> Building the WhatsApp helper for the phone');
  run('sh', [join(ROOT, 'tool/build-whatsappsidecar.sh'), 'android', '--ship'], { cwd: ROOT });
}
// The account helpers for the phone (sidecar/messenger, sidecar/instagram, sidecar/linkedin;
// lib/inbox/account_helper.dart), into jniLibs.
// A LinkedIn helper built into jniLibs before it was removed is packed by no build.
rmSync(join(ROOT, 'android/app/src/main/jniLibs/arm64-v8a/liblinkedinsidecar.so'), { force: true });
// LinkedIn's is no longer carried (Matt, 2026-11-21: "remove the plugin"; lib/inbox/inbox.dart).
for (const name of ['messenger', 'instagram', 'discord', 'twitter', 'slack']) {
  if (!existsSync(join(ROOT, `sidecar/${name}/SOURCE_URL`))) continue;
  say(`> Building the ${name} helper for the phone`);
  run('sh', [join(ROOT, 'tool/build-accountsidecar.sh'), name, 'android', '--ship'], { cwd: ROOT });
}
// The Matrix helper for the phone (sidecar/matrix; lib/inbox/matrix.dart), into jniLibs.
if (existsSync(join(ROOT, 'sidecar/matrix/SOURCE_URL'))) {
  say('> Building the Matrix helper for the phone');
  run('sh', [join(ROOT, 'tool/build-matrixsidecar.sh'), 'android', '--ship'], { cwd: ROOT });
}
// The direct network's core for the phone (native/p2p, Rust on iroh; lib/net/p2p/node_ffi.dart), built into
// build/p2p/android, which the app's jniLibs take in. --no-p2p leaves it out, and takes away one built before so that
// an old one is not packed by mistake: the app then has no direct route and is otherwise the same.
if (args.includes('--no-p2p')) {
  rmSync(join(ROOT, 'build/p2p/android'), { recursive: true, force: true });
  say('  (no direct network core: --no-p2p)');
} else {
  say('> The direct network\'s core for the phone');
  const core = spawnSync('sh', [join(ROOT, 'tool/build-p2p.sh'), 'android'], { cwd: ROOT, stdio: 'inherit' });
  if (core.error || core.status !== 0) fail('The direct network\'s core did not build (tool/build-p2p.sh android). Nothing was sent. To release without the direct route, pass --no-p2p.');
}
// Telegram's library for the Telegram inbox (lib/inbox/telegram.dart), built from Telegram's source (reused while
// the pinned commit is the same) into build/tdlib/android, which the app's jniLibs take in; and the app id.
say('> TDLib for the Telegram inbox');
run('sh', [join(ROOT, 'tool/build-tdlib.sh'), 'android'], { cwd: ROOT });
const telegram = telegramDefines();
say(telegram.said);
run('flutter', ['build', 'apk', '--release', '--target-platform', 'android-arm64', `--build-name=${versionName}`, `--build-number=${versionCode}`, ...telegram.args], { cwd: ROOT });
const built = join(ROOT, 'build/app/outputs/flutter-apk/app-release.apk');
if (!existsSync(built)) fail(`No APK at ${built}.`);
// Under 200 MB, Signal's helper and all (Matt, 2026-11-16: "it's okay as long as our app bundle stays under 200mb").
const apkMb = statSync(built).size / 1048576;
if (apkMb > 200) fail(`The APK is ${apkMb.toFixed(1)} MB: over the 200 MB it is to stay under. Nothing was sent.`);
say(`  the APK is ${apkMb.toFixed(1)} MB`);

// What the APK says it is.
const badging = capture(buildTool('aapt2'), ['dump', 'badging', built]);
const pkg = /^package: name='([^']+)' versionCode='(\d+)' versionName='([^']+)'/m.exec(badging);
if (!pkg) fail('The APK does not say what it is.');
if (pkg[1] !== PACKAGE) fail(`The APK is ${pkg[1]}, not ${PACKAGE}.`);
if (Number(pkg[2]) !== versionCode || pkg[3] !== versionName) fail(`The APK is ${pkg[3]} (${pkg[2]}), not ${versionName} (${versionCode}).`);
if (/^application-debuggable/m.test(badging)) fail('The APK is debuggable.');

// Who signed it.
const certs = capture(buildTool('apksigner'), ['verify', '--print-certs', built]);
const digest = /certificate SHA-256 digest: ([0-9a-f]{64})/i.exec(certs)?.[1]?.toLowerCase();
if (!digest) fail('apksigner did not name the signing certificate.');
if (/CN=Android Debug/.test(certs)) fail('The APK is signed with the debug key: ~/.config/ghostmessaging/signing.properties was not used.');
const pinFile = join(CONFIG, 'cert.sha256');
if (existsSync(pinFile)) {
  const pin = readFileSync(pinFile, 'utf8').trim();
  if (pin !== digest) fail(`The APK is signed by ${digest}, not the release key ${pin}. Installed copies could not update to it.`);
} else {
  writeFileSync(pinFile, `${digest}\n`, { mode: 0o600 });
  say(`ok release certificate pinned: ${digest}`);
}

// The release's files.
const out = join(ROOT, 'build/release');
mkdirSync(out, { recursive: true });
copyFileSync(built, join(out, APK));
const bytes = readFileSync(join(out, APK));
const info = {
  version: versionName,
  versionCode,
  sha256: createHash('sha256').update(bytes).digest('hex'),
  bytes: bytes.length,
  url: APK,
  build: new Date().toISOString().replace(/\D/g, '').slice(0, 14),
};
writeFileSync(join(out, 'apk.json'), `${JSON.stringify(info, null, 2)}\n`);
say(`ok Uplink ${info.version} (code ${info.versionCode}), ${(info.bytes / 1e6).toFixed(1)} MB, in build/release`);
if (!deploy) process.exit(0);

// --- publishing, with Ghost.md's box ------------------------------------------------------------------------------

const { BOX_ENV_KEYS, boxSshOptions, openBox } = await import(pathToFileURL(join(glyph, 'tauri/scripts/lib/box.mjs')).href);
const { loadEnv } = await import(pathToFileURL(join(glyph, 'scripts/lib/env.mjs')).href);
const env = loadEnv(BOX_ENV_KEYS);
const box = openBox(env, boxSshOptions({ connectTimeout: 20 }));
// Asked once more, just before the login: the build took minutes, and it may have been released by someone else
// since this started.
{
  const now = await liveRelease();
  if (now && now.version === versionName && !args.includes('--again')) fail(`${versionName} was released while this was being made (code ${now.versionCode}, published ${now.build ?? 'just now'}). Nothing was sent.`);
}
say('> Logging in to the box');
box.logIn();
const STAGE = '/tmp/ghost-messaging-stage';
box.ssh(`rm -rf ${STAGE} && mkdir -p ${STAGE}`);
say(`> Uploading (${(info.bytes / 1e6).toFixed(1)} MB)`);
box.rsync(['--progress'], join(out, APK), `${STAGE}/${APK}`);
box.rsync([], join(out, 'apk.json'), `${STAGE}/apk.json`);
say('> Publishing');
// The APK first, whole, by rename; apk.json last, so no installed copy is told of an APK still arriving. The live
// files are kept outside the web root first.
box.ssh(`set -e
SUDO=; [ "$(id -u)" -eq 0 ] || SUDO=sudo
[ "$(sha256sum ${STAGE}/${APK} | cut -d' ' -f1)" = "${info.sha256}" ] || { echo "x the APK arrived changed"; exit 1; }
stamp=$(date -u +%Y%m%d%H%M%S)
$SUDO mkdir -p ${RELEASE} ${BACKUPS}
if [ -f ${RELEASE}/apk.json ]; then $SUDO mkdir -p ${BACKUPS}/before-$stamp && $SUDO cp -p ${RELEASE}/* ${BACKUPS}/before-$stamp/; fi
$SUDO install -m 644 -o root -g root ${STAGE}/${APK} ${RELEASE}/.${APK}.new
$SUDO mv -f ${RELEASE}/.${APK}.new ${RELEASE}/${APK}
$SUDO install -m 644 -o root -g root ${STAGE}/apk.json ${RELEASE}/.apk.json.new
$SUDO mv -f ${RELEASE}/.apk.json.new ${RELEASE}/apk.json
$SUDO chmod 755 ${RELEASE}
rm -rf ${STAGE}
echo "ok placed in ${RELEASE}"`);

// Is it served? gogho.st's block reads the folder it was put in. Where it answers otherwise, the block is shown:
// before tool/deploy-site.mjs --caddy has run once there is none, and the release waits in its folder.
const res = await fetch(`${HOST_URL}/apk.json?t=${Date.now()}`, { cache: 'no-store' }).catch((e) => ({ ok: false, status: e.message }));
const said = res.ok ? await res.json().catch(() => null) : null;
if (said?.sha256 !== info.sha256) {
  say(`x ${HOST_URL}/apk.json answered ${res.status}, not this release. The release is in ${RELEASE} on the box.`);
  say('  If gogho.st has no Caddy block yet: node tool/deploy-site.mjs --caddy. Its block, for a look:');
  box.ssh(`grep -n -A25 '^gogho.st' /etc/caddy/Caddyfile || echo "(none)"`);
  if (!keepConnection) box.close();
  process.exit(1);
}
if (!keepConnection) box.close();
const head = await fetch(`${HOST_URL}/${APK}`, { method: 'HEAD' });
say(`ok live: ${HOST_URL}/ — Uplink ${info.version}, APK served at ${head.headers.get('content-length')} bytes (${info.bytes} expected)`);

// The source, published as this release has it (tool/publish-source.mjs; Matt, 2026-11-15: "update the notes on claude
// so that each release runs this automatically"). The release is live either way: a failure here is said, not fatal.
if (!process.argv.includes('--no-source')) {
  say('> Publishing the source (github.com/InfamousVague/ghost-messaging)');
  const published = spawnSync('node', [join(ROOT, 'tool/publish-source.mjs')], { stdio: 'inherit' });
  if (published.status !== 0) say('x The source was not published; run node tool/publish-source.mjs');
}

// The web client at gogho.st/app, built from this checkout and shipped with the site (tool/release-web.mjs; GMFB-30:
// it followed no release while it was deployed by hand). The release is live either way: a failure here is said, not
// fatal. --no-web leaves it out.
if (!args.includes('--no-web')) {
  say('> The web client (gogho.st/app)');
  const web = spawnSync('node', [join(ROOT, 'tool/release-web.mjs'), '--glyph', glyph, ...(keepConnection ? ['--keep-connection'] : [])], { cwd: ROOT, stdio: 'inherit' });
  if (web.status !== 0) say('x The web client was not published; run node tool/release-web.mjs');
} else {
  say('  (the web client not published: --no-web)');
}
