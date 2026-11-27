#!/usr/bin/env node
/**
 * Builds and signs Uplink for the Mac, makes what an installed copy updates itself from, and (when asked)
 * installs it on this Mac or publishes it. Matt, 2026-11-13: "install the app on my mac and make sure it has OTA
 * updates so we don't need to reinstall again".
 *
 *   node tool/release-mac.mjs                        # build, sign, zip, describe: into build/release-mac
 *   node tool/release-mac.mjs --install              # ...and put the app in /Applications (once: it updates itself after)
 *   node tool/release-mac.mjs --notarize             # ...and have Apple notarise it and staple the ticket
 *   node tool/release-mac.mjs --publish [--glyph ~/path/to/glyph] [--keep-connection] [--again]
 *                                                    # ...and put the zip and its description on the box
 *   --no-p2p          leave the direct network's core out (the app then has no direct route, and is otherwise the same)
 *   --version 0.6.2   the version's name (pubspec.yaml's otherwise)
 *   --build 455123    its number (see below)
 *   --replace         with --install: take the place of a copy already in /Applications
 *
 * WHAT AN INSTALLED COPY READS (lib/desktop/updates.dart, macos/Runner/UpdatesChannel.swift):
 *
 *   https://gogho.st/mac.json                 { version, versionCode, sha256, bytes, url, build, minimumSystemVersion }
 *   https://gogho.st/ghost-messaging-mac.zip  the signed app, zipped by ditto
 *
 * WHAT A PERSON DOWNLOADS from the site (Matt, 2026-11-19: "deploy it from a dmg"): ghost-messaging-mac.dmg, the
 * notarised app beside a shortcut to Applications, the disk image itself signed, notarised and stapled, so it opens
 * in Finder with nothing to unpack and macOS checks it as it is mounted. Made only with --notarize; mac.json names it
 * (`dmg`), which an installed copy leaves alone: updates stay the zip.
 *
 * beside the phone app's apk.json, in /opt/ghost-sms-release. ghost-sms.com's Caddy block serves that folder's
 * files by name (tool/deploy-site.mjs): the two above were added to it with this tool, and the block on the box
 * has named them since 2026-11-14 (it went up again with the relay), so the first Mac release needs nothing first.
 *
 * THE NUMBER (`CFBundleVersion`, `versionCode`) is what newer is asked of, and an installed copy never steps back.
 * It is the minutes since 2026 began, so it rises by itself and needs nothing kept; one above the live release's
 * where that is not higher. The phone app's version code is another number and has nothing to do with it.
 *
 * WHO SIGNS IT is what makes an update believed. The app is signed inside out with the Developer ID
 * ("Developer ID Application: Matt Wisniewski (F6ZAL7ANAD)", in this Mac's keychain, as Ghost.md's Mac app is:
 * scripts/deploy-flutter-mac.mjs in the repository's root) under the hardened runtime. An installed copy takes an
 * update only if it is whole and signed by its own team, whatever the server says, so there is no second key to
 * keep or lose. A build signed any other way is refused here: no installed copy would take it.
 *
 * NOTARISING is for a copy someone downloads with a browser, which macOS will not open otherwise. A copy that
 * updates itself, or is put in /Applications by --install, is not asked for it. --notarize uses the shared
 * MattsSoftware App Store Connect key (~/.config/mattssoftware/signing/asc-api.env, or APPLE_API_ISSUER,
 * APPLE_API_KEY and APPLE_API_KEY_PATH), as Ghost.md's does.
 *
 * PUBLISHING is as tool/release.mjs does it, with Ghost.md's box code and credentials and one login: the zip first,
 * whole and by rename, and mac.json last, so no installed copy is told of a zip still arriving. It is never done
 * unless --publish is given.
 */
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs';
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
const ZIP = 'ghost-messaging-mac.zip';
const DMG = 'ghost-messaging-mac.dmg';
const FEED = 'mac.json';
const APP = 'Uplink.app';
// What the app's file was called until 2026-11-27. A copy installed then keeps that name: it updates itself in place.
const APP_BEFORE = 'Ghost Messaging.app';
const BUNDLE_ID = 'com.infamousvague.ghostmessaging.mac';
const TEAM = 'F6ZAL7ANAD';
const IDENTITY = process.env.GHOST_MAC_IDENTITY ?? `Developer ID Application: Matt Wisniewski (${TEAM})`;
const OUT = join(ROOT, 'build/release-mac');

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
/** Runs a tool with its output shown, and stops the release if it fails. */
const run = (cmd, cmdArgs, options = {}) => {
  const result = spawnSync(cmd, cmdArgs, { stdio: 'inherit', ...options });
  if (result.error) fail(`${cmd} could not run: ${result.error.message}`);
  if (result.status !== 0) fail(`${cmd} ${cmdArgs.join(' ')} failed (${result.status}).`);
  return result;
};
/** What a tool printed, both streams (codesign describes on stderr); '' where it failed. */
const read = (cmd, cmdArgs) => {
  const result = spawnSync(cmd, cmdArgs, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  return result.status === 0 ? `${result.stdout}${result.stderr}` : '';
};

if (process.platform !== 'darwin') fail('The Mac app is built and signed on a Mac.');

// --- the version ----------------------------------------------------------------------------------------------------

/** The version's name in pubspec.yaml, without its build number: the Mac's build number is made below. */
function pubspecVersion() {
  const match = /^version:\s*([0-9]+\.[0-9]+\.[0-9]+)/m.exec(readFileSync(join(ROOT, 'pubspec.yaml'), 'utf8'));
  if (!match) fail('pubspec.yaml has no version.');
  return match[1];
}

/** The live release's description; null where none has been published. */
async function liveRelease() {
  try {
    const res = await fetch(`${HOST_URL}/${FEED}?t=${Date.now()}`, { cache: 'no-store' });
    if (res.status === 404) return null;
    if (!res.ok) fail(`${HOST_URL}/${FEED} answered ${res.status}.`);
    return await res.json();
  } catch (e) {
    fail(`Could not read the live Mac release: ${e.message}`);
  }
}

const live = await liveRelease();
const versionName = flag('version') ?? pubspecVersion();
requireNotes(ROOT, versionName, args, fail);
// The build number is the minutes since the start of 2026 (UTC) unless --build gives one: it only ever goes up,
// and is always above the live release's.
const minutes = Math.floor((Date.now() - Date.UTC(2026, 0, 1)) / 60000);
const versionCode = flag('build') ? Number(flag('build')) : Math.max(minutes, (live?.versionCode ?? 0) + 1);
if (!Number.isInteger(versionCode) || versionCode <= 0) fail(`--build ${flag('build')} is not a number.`);
if (live && versionCode <= live.versionCode) fail(`Build ${versionCode} is not above the live release's ${live.versionCode}: no installed copy would take it.`);
// A version that is live already is not published a second time. Two sessions were once told to release 0.7.10
// within minutes of each other (2026-11-14): one published it while the other was waiting for the box's login
// window, and the second was stopped by hand only because the line below this one said what was live. The branch's
// version goes up as each release is recorded, so the same name live means someone has released it since.
if (has('publish') && live && live.version === versionName && !has('again')) {
  fail(`${versionName} is live already (${live.versionCode}, published ${live.build ?? 'earlier'}): someone has released it. Nothing was built or sent. If it really is to go out again under the same name, pass --again.`);
}
// The guard tests (tool/lib/guards.mjs): what the source must keep for every build, read before one is made.
requireGuards(ROOT, fail);
say(`> Building Uplink for the Mac ${versionName} (${versionCode}; live is ${live ? `${live.version} (${live.versionCode})` : 'nothing yet'})`);

if (!read('security', ['find-identity', '-v', '-p', 'codesigning']).includes(`"${IDENTITY}"`)) {
  fail(`No signing identity "${IDENTITY}" in this Mac's keychain: an installed copy takes only what its own team signed.`);
}

// --- the build ------------------------------------------------------------------------------------------------------

// DeepFilterNet for calls (native/voicefx/deepfilter), built fresh so the app carries it; without it, RNNoise alone.
say('> Building DeepFilterNet for calls');
run('sh', [join(ROOT, 'native/voicefx/deepfilter/build.sh')], { cwd: ROOT });
// TDLib for the Telegram inbox (lib/inbox/telegram.dart), built from Telegram's source, and the app id.
say('> TDLib for the Telegram inbox');
run('sh', [join(ROOT, 'tool/build-tdlib.sh'), 'mac'], { cwd: ROOT });
// The direct network's core (native/p2p, Rust on iroh; lib/net/p2p/node_ffi.dart), for both kinds of Mac in one file.
const p2pCore = join(ROOT, 'build/p2p/mac/libghost_p2p.dylib');
if (has('no-p2p')) {
  say('  (no direct network core: --no-p2p)');
} else {
  say('> The direct network\'s core');
  const core = spawnSync('sh', [join(ROOT, 'tool/build-p2p.sh'), 'mac'], { cwd: ROOT, stdio: 'inherit' });
  if (core.error || core.status !== 0) fail('The direct network\'s core did not build (tool/build-p2p.sh mac). To build without the direct route, pass --no-p2p.');
}
const telegram = telegramDefines();
say(telegram.said);
run('flutter', ['build', 'macos', '--release', `--build-name=${versionName}`, `--build-number=${versionCode}`, ...telegram.args], { cwd: ROOT });
const built = join(ROOT, 'build/macos/Build/Products/Release', APP);
if (!existsSync(join(built, 'Contents/Info.plist'))) fail(`No app at ${built}.`);

// A copy is signed, never the build's own output: a second run starts from the same bytes.
rmSync(OUT, { recursive: true, force: true });
mkdirSync(OUT, { recursive: true });
const app = join(OUT, APP);
run('ditto', [built, app]);

// The Google Messages sidecar (sidecar/gmessages, AGPL-3.0), in Contents/Helpers: only once its source is public
// (sidecar/gmessages/SOURCE_URL names where), since the AGPL asks that of every copy given out.
const sidecarSource = join(ROOT, 'sidecar/gmessages/SOURCE_URL');
const helper = join(app, 'Contents/Helpers/gmsidecar');
if (existsSync(sidecarSource)) {
  say('> Building the Google Messages sidecar');
  run('sh', [join(ROOT, 'tool/build-gmsidecar.sh'), 'mac'], { cwd: ROOT });
  mkdirSync(join(app, 'Contents/Helpers'), { recursive: true });
  run('ditto', [join(ROOT, 'build/gmsidecar/mac/gmsidecar'), helper]);
  run('ditto', [join(ROOT, 'sidecar/gmessages/LICENSE'), join(app, 'Contents/Resources/gmsidecar-LICENSE.txt')]);
  run('ditto', [sidecarSource, join(app, 'Contents/Resources/gmsidecar-SOURCE.txt')]);
} else {
  say('  (no Google Messages sidecar: its source is not published yet, sidecar/gmessages/SOURCE_URL)');
}

// The Signal helper (sidecar/signal, AGPL-3.0; lib/inbox/signal.dart), in Contents/Helpers beside the Google Messages
// one, Apple silicon only (on an Intel Mac Signal says it isn't in this build); signed with the rest below.
const signalSource = join(ROOT, 'sidecar/signal/SOURCE_URL');
const signalHelper = join(app, 'Contents/Helpers/signal-sidecar');
if (existsSync(signalSource)) {
  say('> Building the Signal helper');
  run('sh', [join(ROOT, 'tool/build-signalsidecar.sh'), 'mac'], { cwd: ROOT });
  mkdirSync(join(app, 'Contents/Helpers'), { recursive: true });
  run('ditto', [join(ROOT, 'build/signal-sidecar/mac/signal-sidecar'), signalHelper]);
  run('ditto', [join(ROOT, 'sidecar/signal/LICENSE'), join(app, 'Contents/Resources/signal-sidecar-LICENSE.txt')]);
  run('ditto', [signalSource, join(app, 'Contents/Resources/signal-sidecar-SOURCE.txt')]);
}

// The WhatsApp helper (sidecar/whatsapp, on whatsmeow, MPL-2.0; lib/inbox/whatsapp.dart; Matt, 2026-11-17: "enable
// whatsapp but warn the user that it's unsupported by whatsapp"), beside Signal's, signed with the rest below.
const waSource = join(ROOT, 'sidecar/whatsapp/SOURCE_URL');
const waHelper = join(app, 'Contents/Helpers/whatsapp-sidecar');
if (existsSync(waSource)) {
  say('> Building the WhatsApp helper');
  run('sh', [join(ROOT, 'tool/build-whatsappsidecar.sh'), 'mac'], { cwd: ROOT });
  mkdirSync(join(app, 'Contents/Helpers'), { recursive: true });
  run('ditto', [join(ROOT, 'build/whatsapp-sidecar/mac/whatsapp-sidecar'), waHelper]);
  run('ditto', [join(ROOT, 'sidecar/whatsapp/LICENSE'), join(app, 'Contents/Resources/whatsapp-sidecar-LICENSE.txt')]);
  run('ditto', [waSource, join(app, 'Contents/Resources/whatsapp-sidecar-SOURCE.txt')]);
}

// The account helpers (sidecar/messenger, sidecar/instagram, sidecar/linkedin; sidecar/ACCOUNT_HELPERS.md;
// lib/inbox/account_helper.dart; Matt, 2026-11-20: "Let's do the feasible ones but skip X and google voice"), each
// carried where it is in the checkout with its source's address, beside the others and signed with the rest below.
const accountHelpers = [];
// LinkedIn's is no longer carried (Matt, 2026-11-21: "remove the plugin"; lib/inbox/inbox.dart).
for (const name of ['messenger', 'instagram', 'discord', 'twitter', 'slack']) {
  const source = join(ROOT, `sidecar/${name}/SOURCE_URL`);
  if (!existsSync(source)) continue;
  say(`> Building the ${name} helper`);
  run('sh', [join(ROOT, 'tool/build-accountsidecar.sh'), name, 'mac'], { cwd: ROOT });
  mkdirSync(join(app, 'Contents/Helpers'), { recursive: true });
  const helper = join(app, `Contents/Helpers/${name}-sidecar`);
  run('ditto', [join(ROOT, `build/${name}-sidecar/mac/${name}-sidecar`), helper]);
  run('ditto', [join(ROOT, `sidecar/${name}/LICENSE`), join(app, `Contents/Resources/${name}-sidecar-LICENSE.txt`)]);
  run('ditto', [source, join(app, `Contents/Resources/${name}-sidecar-SOURCE.txt`)]);
  accountHelpers.push(helper);
}

// The Matrix helper (sidecar/matrix, on mautrix-go with goolm's encryption; lib/inbox/matrix.dart; Matt, 2026-11-17:
// "Let's add support for matrix"), beside Signal's, signed with the rest below.
const matrixSource = join(ROOT, 'sidecar/matrix/SOURCE_URL');
const matrixHelper = join(app, 'Contents/Helpers/matrix-sidecar');
if (existsSync(matrixSource)) {
  say('> Building the Matrix helper');
  run('sh', [join(ROOT, 'tool/build-matrixsidecar.sh'), 'mac'], { cwd: ROOT });
  mkdirSync(join(app, 'Contents/Helpers'), { recursive: true });
  run('ditto', [join(ROOT, 'build/matrix-sidecar/mac/matrix-sidecar'), matrixHelper]);
  run('ditto', [join(ROOT, 'sidecar/matrix/LICENSE'), join(app, 'Contents/Resources/matrix-sidecar-LICENSE.txt')]);
  run('ditto', [matrixSource, join(app, 'Contents/Resources/matrix-sidecar-SOURCE.txt')]);
}

// TDLib in Contents/Frameworks, where lib/inbox/td_json.dart opens it; signed with the rest below. Apple silicon
// only: on an Intel Mac Telegram says it isn't in this build.
mkdirSync(join(app, 'Contents/Frameworks'), { recursive: true });
run('ditto', [join(ROOT, 'build/tdlib/mac/libtdjson.dylib'), join(app, 'Contents/Frameworks/libtdjson.dylib')]);
// The direct network's core beside it, where lib/net/p2p/node_ffi_io.dart opens it; signed with the rest below (its
// own signature is nobody's: tool/build-p2p.sh). Left out with --no-p2p, and the app finds none.
if (!has('no-p2p')) run('ditto', [p2pCore, join(app, 'Contents/Frameworks/libghost_p2p.dylib')]);

// The built app is checked before it is signed: its id, its version, the local network's reason, Apple silicon.
const plist = JSON.parse(read('plutil', ['-convert', 'json', '-o', '-', join(app, 'Contents/Info.plist')]) || '{}');
if (plist.CFBundleIdentifier !== BUNDLE_ID) fail(`The app's id is ${plist.CFBundleIdentifier}, not ${BUNDLE_ID}.`);
if (plist.CFBundleShortVersionString !== versionName || String(plist.CFBundleVersion) !== String(versionCode)) {
  fail(`The app says ${plist.CFBundleShortVersionString} (${plist.CFBundleVersion}), not ${versionName} (${versionCode}).`);
}
if (!plist.NSLocalNetworkUsageDescription) fail('The app has no NSLocalNetworkUsageDescription: macOS would not let it look for the phone.');
const executable = join(app, 'Contents/MacOS', String(plist.CFBundleExecutable ?? ''));
const archs = read('lipo', ['-archs', executable]).trim().split(/\s+/).filter(Boolean);
if (!archs.includes('arm64')) fail(`The app is built for ${archs.join(', ') || 'nothing'}, not Apple silicon.`);

// --- signing --------------------------------------------------------------------------------------------------------

/** Everything under [dir], a folder's contents before the folder itself, so the innermost code is signed first. */
function walk(dir) {
  const found = [];
  for (const name of readdirSync(dir, { withFileTypes: true })) {
    const at = join(dir, name.name);
    if (name.isSymbolicLink()) continue;
    if (name.isDirectory()) found.push(...walk(at), at);
    else found.push(at);
  }
  return found;
}

say('> Signing the app, inside out');
const entitlements = join(ROOT, 'macos/Runner/Release.entitlements');
// Developer ID, a secure timestamp and the hardened runtime: what notarisation asks of every piece of code.
const sign = (target, more = []) => run('codesign', ['--force', '--timestamp', '--options', 'runtime', '--sign', IDENTITY, ...more, target], { stdio: ['ignore', 'ignore', 'inherit'] });
const frameworks = join(app, 'Contents/Frameworks');
if (existsSync(frameworks)) {
  for (const at of walk(frameworks)) {
    const isBundle = /\.(framework|bundle|xpc|app)$/.test(at) && statSync(at).isDirectory();
    const isCode = !isBundle && statSync(at).isFile() && (/\.dylib$/.test(at) || /Mach-O/.test(read('file', ['-b', at])));
    if (isBundle || isCode) sign(at);
  }
}
if (existsSync(helper)) sign(helper);
if (existsSync(signalHelper)) sign(signalHelper);
if (existsSync(waHelper)) sign(waHelper);
if (existsSync(matrixHelper)) sign(matrixHelper);
for (const helper of accountHelpers) sign(helper);
sign(app, ['--entitlements', entitlements]);

const verified = spawnSync('codesign', ['--verify', '--deep', '--strict', app], { encoding: 'utf8' });
if (verified.status !== 0) fail(`codesign does not verify the signed app:\n${verified.stderr}`);
const signing = read('codesign', ['-dv', '--verbose=2', app]);
if (/TeamIdentifier=(\S+)/.exec(signing)?.[1] !== TEAM) fail(`The app is not signed by team ${TEAM}.`);
if (!/flags=\S*\(.*runtime.*\)/.test(signing)) fail('The app is not signed with the hardened runtime.');
// What an installed copy asks of an update (UpdatesChannel.signatureRefused), asked here first.
const asked = spawnSync('codesign', ['--verify', '--deep', '--strict', `-R=anchor apple generic and certificate leaf[subject.OU] = "${TEAM}"`, app], { encoding: 'utf8' });
if (asked.status !== 0) fail(`The app does not meet what an installed copy asks of an update:\n${asked.stderr}`);
if (read('codesign', ['-d', '--entitlements', ':-', app]).includes('com.apple.security.app-sandbox')) fail('The app is sandboxed: it could not replace itself with an update.');
say(`ok signed by team ${TEAM} (Developer ID, hardened runtime), ${archs.join(' + ')}, macOS ${plist.LSMinimumSystemVersion}+`);

// --- notarising, when asked -----------------------------------------------------------------------------------------

/**
 * The App Store Connect API key notarytool signs in with: from the environment, or the file the other apps share.
 * Null where any of the three parts is missing or the key file is not there.
 */
function notaryCredentials() {
  let issuer = process.env.APPLE_API_ISSUER;
  let keyId = process.env.APPLE_API_KEY;
  let keyPath = process.env.APPLE_API_KEY_PATH;
  const shared = join(homedir(), '.config/mattssoftware/signing/asc-api.env');
  if (!(issuer && keyId && keyPath) && existsSync(shared)) {
    const kept = Object.fromEntries(
      readFileSync(shared, 'utf8')
        .split('\n')
        .map((line) => /^\s*(?:export\s+)?([A-Z_]+)\s*=\s*"?([^"\n]*?)"?\s*$/.exec(line))
        .filter(Boolean)
        .map((match) => [match[1], match[2]]),
    );
    issuer ||= kept.ASC_ISSUER_ID;
    keyId ||= kept.ASC_KEY_ID;
    // The shared file is written for a shell to read, and names the key under $HOME (or ~): said in full here, or
    // the key is "not there" and --notarize stops (as it did on 2026-11-14, until the three were passed in).
    keyPath ||= kept.ASC_KEY_PATH?.replace(/^\$\{?HOME\}?(?=\/)|^~(?=\/)/, homedir());
  }
  return issuer && keyId && keyPath && existsSync(keyPath) ? { issuer, keyId, keyPath } : null;
}

let notarised = false;
if (has('notarize')) {
  const notary = notaryCredentials();
  if (!notary) fail('No notarisation key: set APPLE_API_ISSUER, APPLE_API_KEY and APPLE_API_KEY_PATH, or keep the shared one in ~/.config/mattssoftware/signing/asc-api.env.');
  say('> Notarising the app (Apple reads it; a few minutes)');
  const sent = join(OUT, 'for-apple.zip');
  run('ditto', ['-c', '-k', '--keepParent', app, sent]);
  run('xcrun', ['notarytool', 'submit', sent, '--key', notary.keyPath, '--key-id', notary.keyId, '--issuer', notary.issuer, '--wait']);
  rmSync(sent);
  run('xcrun', ['stapler', 'staple', app]);
  if (spawnSync('xcrun', ['stapler', 'validate', app], { encoding: 'utf8' }).status !== 0) fail('The app has no notarisation ticket stapled to it.');
  notarised = true;
  say('ok notarised, and the ticket stapled');
}

// --- what an installed copy reads -----------------------------------------------------------------------------------

const zip = join(OUT, ZIP);
// Without the files' extended attributes (Matt, 2026-11-19: "my friend is not able to launch the mac app it says apple
// can't verify it's free from malware"). ditto keeps them in a zip as "._" files beside each file; Finder folds those
// back, but unzip and most other unarchivers write them into the app as files of their own, inside a sealed, signed
// framework (784 of them, Dav1d.framework's first), so the signature no longer holds and Gatekeeper refuses the app.
// The signature and the stapled ticket are files of the bundle's own and need none of them.
run('ditto', ['-c', '-k', '--norsrc', '--noextattr', '--noqtn', '--noacl', '--keepParent', app, zip]);
// What a person downloads must open however it is unpacked: no "._" file in it.
if (spawnSync('unzip', ['-Z1', zip], { encoding: 'utf8', maxBuffer: 64 * 1048576 }).stdout.split('\n').some((n) => /(^|\/)\._/.test(n) || n.startsWith('__MACOSX'))) fail('The zip still carries "._" files, which break the app\'s signature where unzip unpacks it. Nothing was published.');
const bytes = readFileSync(zip);
// Under 200 MB, Signal's helper and all (Matt, 2026-11-16: "it's okay as long as our app bundle stays under 200mb").
if (bytes.length > 200 * 1048576) fail(`The Mac app's zip is ${(bytes.length / 1048576).toFixed(1)} MB: over 200 MB. Nothing was published.`);
say(`  the zip is ${(bytes.length / 1048576).toFixed(1)} MB`);
// --- what a person downloads: a disk image, notarised in its own right -------------------------------------------------

let dmg = null;
if (notarised) {
  say('> Making the disk image');
  const stage = join(OUT, 'dmg-stage');
  rmSync(stage, { recursive: true, force: true });
  mkdirSync(stage, { recursive: true });
  run('ditto', ['--norsrc', '--noextattr', '--noqtn', '--noacl', app, join(stage, APP)]);
  run('ln', ['-s', '/Applications', join(stage, 'Applications')]);
  const path = join(OUT, DMG);
  rmSync(path, { force: true });
  run('hdiutil', ['create', '-volname', 'Uplink', '-srcfolder', stage, '-fs', 'HFS+', '-format', 'UDZO', '-imagekey', 'zlib-level=9', '-ov', path]);
  rmSync(stage, { recursive: true, force: true });
  run('codesign', ['--sign', IDENTITY, '--timestamp', path]);
  say('> Notarising the disk image (a few minutes)');
  const notary = notaryCredentials();
  run('xcrun', ['notarytool', 'submit', path, '--key', notary.keyPath, '--key-id', notary.keyId, '--issuer', notary.issuer, '--wait']);
  run('xcrun', ['stapler', 'staple', path]);
  if (spawnSync('xcrun', ['stapler', 'validate', path], { encoding: 'utf8' }).status !== 0) fail('The disk image has no notarisation ticket stapled to it.');
  // As Gatekeeper asks of a downloaded disk image when it is opened.
  const gate = spawnSync('spctl', ['-a', '-t', 'open', '--context', 'context:primary-signature', '-vv', path], { encoding: 'utf8' });
  if (gate.status !== 0 || !/source=Notarized Developer ID/.test(gate.stderr)) fail(`Gatekeeper would not open the disk image:\n${gate.stderr}`);
  const image = readFileSync(path);
  dmg = { url: DMG, sha256: createHash('sha256').update(image).digest('hex'), bytes: image.length };
  say(`ok the disk image is ${(image.length / 1048576).toFixed(1)} MB, signed, notarised and stapled`);
}

const info = {
  version: versionName,
  versionCode,
  sha256: createHash('sha256').update(bytes).digest('hex'),
  bytes: bytes.length,
  url: ZIP,
  build: new Date().toISOString().replace(/\D/g, '').slice(0, 14),
  minimumSystemVersion: String(plist.LSMinimumSystemVersion ?? ''),
  ...(dmg ? { dmg } : {}),
};
writeFileSync(join(OUT, FEED), `${JSON.stringify(info, null, 2)}\n`);
say(`ok Uplink for the Mac ${info.version} (${info.versionCode}), ${(info.bytes / 1e6).toFixed(1)} MB zipped${notarised ? ', notarised' : ''}, in build/release-mac`);

// --- on this Mac ----------------------------------------------------------------------------------------------------

if (has('install')) {
  const folder = resolve(flag('install-to') ?? '/Applications');
  const dest = join(folder, APP);
  const before = join(folder, APP_BEFORE);
  if (existsSync(before) && !existsSync(dest)) fail(`${before} is there, under the app's earlier name. Rename it to ${APP} (it keeps updating itself under any name) or remove it first: two copies would both take the app's links.`);
  let aside = null;
  if (existsSync(dest)) {
    if (!has('replace')) fail(`${dest} is there already. It updates itself; --replace takes its place with this build.`);
    if (read('pgrep', ['-f', join(dest, 'Contents/MacOS')]).trim()) fail(`${dest} is running. Quit it first.`);
    aside = join(folder, `.${APP}-replaced-${info.build}`);
    renameSync(dest, aside);
  }
  run('ditto', [app, dest]);
  if (spawnSync('codesign', ['--verify', '--deep', '--strict', dest], { encoding: 'utf8' }).status !== 0) {
    if (aside) {
      rmSync(dest, { recursive: true, force: true });
      renameSync(aside, dest);
    }
    fail(`The copy in ${folder} does not verify; ${aside ? 'the one that was there is back' : 'nothing was there before'}.`);
  }
  if (aside) rmSync(aside, { recursive: true, force: true });
  say(`ok installed: ${dest}`);
}

if (!has('publish')) process.exit(0);

// --- publishing, with Ghost.md's box --------------------------------------------------------------------------------

if (!notarised) say('! Not notarised: right for copies that update themselves, not for a download from a browser.');
const glyph = [flag('glyph'), process.env.GLYPH_ROOT, join(ROOT, '..'), join(ROOT, '..', 'glyph'), join(homedir(), 'Development/Apps/glyph')]
  .filter(Boolean)
  .find((dir) => existsSync(join(dir, 'tauri/scripts/lib/box.mjs')) && existsSync(join(dir, 'scripts/lib/env.mjs')));
if (!glyph) fail('No Ghost.md checkout found for its box code (--glyph <path> or GLYPH_ROOT).');
const { BOX_ENV_KEYS, boxSshOptions, openBox } = await import(pathToFileURL(join(glyph, 'tauri/scripts/lib/box.mjs')).href);
const { loadEnv } = await import(pathToFileURL(join(glyph, 'scripts/lib/env.mjs')).href);
const env = loadEnv(BOX_ENV_KEYS);
const box = openBox(env, boxSshOptions({ connectTimeout: 20 }));
const keepConnection = has('keep-connection');
// Asked once more, just before the login: building and Apple's reading took minutes, and it may have been
// released by someone else since this started.
{
  const now = await liveRelease();
  if (now && now.version === versionName && !has('again')) fail(`${versionName} was released while this was being made (${now.versionCode}, published ${now.build ?? 'just now'}). Nothing was sent.`);
}
say('> Logging in to the box');
box.logIn();
const STAGE = '/tmp/ghost-messaging-mac-stage';
box.ssh(`rm -rf ${STAGE} && mkdir -p ${STAGE}`);
say(`> Uploading (${(info.bytes / 1e6).toFixed(1)} MB)`);
box.rsync(['--progress'], zip, `${STAGE}/${ZIP}`);
if (dmg) box.rsync(['--progress'], join(OUT, DMG), `${STAGE}/${DMG}`);
box.rsync([], join(OUT, FEED), `${STAGE}/${FEED}`);
say('> Publishing');
// The zip first, whole, by rename; mac.json last, so no installed copy is told of a zip still arriving. The live
// two are kept outside the web root first.
box.ssh(`set -e
SUDO=; [ "$(id -u)" -eq 0 ] || SUDO=sudo
[ "$(sha256sum ${STAGE}/${ZIP} | cut -d' ' -f1)" = "${info.sha256}" ] || { echo "x the zip arrived changed"; exit 1; }
stamp=$(date -u +%Y%m%d%H%M%S)
$SUDO mkdir -p ${RELEASE} ${BACKUPS}
if [ -f ${RELEASE}/${FEED} ]; then $SUDO mkdir -p ${BACKUPS}/mac-before-$stamp && $SUDO cp -p ${RELEASE}/${FEED} ${RELEASE}/${ZIP} ${BACKUPS}/mac-before-$stamp/; fi
if [ -f ${RELEASE}/${DMG} ]; then $SUDO cp -p ${RELEASE}/${DMG} ${BACKUPS}/mac-before-$stamp/ 2>/dev/null || true; fi
$SUDO install -m 644 -o root -g root ${STAGE}/${ZIP} ${RELEASE}/.${ZIP}.new
$SUDO mv -f ${RELEASE}/.${ZIP}.new ${RELEASE}/${ZIP}
${dmg ? `[ "$(sha256sum ${STAGE}/${DMG} | cut -d' ' -f1)" = "${dmg.sha256}" ] || { echo "x the disk image arrived changed"; exit 1; }
$SUDO install -m 644 -o root -g root ${STAGE}/${DMG} ${RELEASE}/.${DMG}.new
$SUDO mv -f ${RELEASE}/.${DMG}.new ${RELEASE}/${DMG}` : ''}
$SUDO install -m 644 -o root -g root ${STAGE}/${FEED} ${RELEASE}/.${FEED}.new
$SUDO mv -f ${RELEASE}/.${FEED}.new ${RELEASE}/${FEED}
$SUDO chmod 755 ${RELEASE}
rm -rf ${STAGE}
echo "ok placed in ${RELEASE}"`);

// Is it served? gogho.st's block names the files it serves from that folder (tool/deploy-site.mjs).
// Asked a few times: twice (0.9.31, 0.9.32) the first ask, just after the upload, failed to reach the site at all
// ("fetch failed") while the release was live and whole, and the step said it had failed.
let res = { ok: false, status: 'not asked' };
let said = null;
for (let i = 0; i < 6 && said?.sha256 !== info.sha256; i++) {
  if (i) await new Promise((r) => setTimeout(r, 5000));
  res = await fetch(`${HOST_URL}/${FEED}?t=${Date.now()}`, { cache: 'no-store' }).catch((e) => ({ ok: false, status: e.message }));
  said = res.ok ? await res.json().catch(() => null) : null;
}
if (!keepConnection) box.close();
if (said?.sha256 !== info.sha256) {
  say(`x ${HOST_URL}/${FEED} answered ${res.status}, not this release. The release is in ${RELEASE} on the box.`);
  say(`  gogho.st's Caddy block should name /${FEED} and /${ZIP} (it has since 2026-11-14). If it no longer does: node tool/deploy-site.mjs --caddy`);
  process.exit(1);
}
const head = await fetch(`${HOST_URL}/${ZIP}`, { method: 'HEAD' }).catch(() => ({ headers: { get: () => '?' } }));
say(`ok live: ${HOST_URL}/${FEED} — Uplink for the Mac ${info.version} (${info.versionCode}), zip served at ${head.headers.get('content-length')} bytes (${info.bytes} expected)`);
if (dmg) {
  const d = await fetch(`${HOST_URL}/${DMG}`, { method: 'HEAD' }).catch(() => null);
  const served = d?.ok ? Number(d.headers.get('content-length')) : 0;
  say(served === dmg.bytes
    ? `ok live: ${HOST_URL}/${DMG}, served at ${served} bytes`
    : `! ${HOST_URL}/${DMG} isn't served yet (${d?.status ?? 'no answer'}): it is in ${RELEASE}; gogho.st's Caddy block must name it (node tool/deploy-site.mjs --caddy).`);
}

// The source, published as this release has it (tool/publish-source.mjs; Matt, 2026-11-15: "update the notes on claude
// so that each release runs this automatically"). The release is live either way: a failure here is said, not fatal.
if (!process.argv.includes('--no-source')) {
  say('> Publishing the source (github.com/InfamousVague/ghost-messaging)');
  const published = spawnSync('node', [join(ROOT, 'tool/publish-source.mjs')], { stdio: 'inherit' });
  if (published.status !== 0) say('x The source was not published; run node tool/publish-source.mjs');
}
