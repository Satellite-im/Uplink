#!/usr/bin/env node
/**
 * Builds Uplink for a browser (Matt: "the full web client"; docs/OPEN_NETWORK.md, part 6): a folder of plain
 * files a relay serves under /app/ (relay/lib/web_app.dart). It builds and says how big the result is. It does not
 * put it anywhere.
 *
 *   node tool/build-web.mjs                   the release build, into build/web, for a relay's /app/ (its own hub)
 *   node tool/build-web.mjs --app             the build for app.gogho.st, into build/web-app: served from /, speaking
 *                                             to gogho.st's hub (tool/lib/web_site.mjs); tool/deploy-site.mjs --app
 *                                             build/web-app ships it
 *   node tool/build-web.mjs --profile         names kept in the JavaScript, for reading what went wrong
 *   node tool/build-web.mjs --out <folder>    somewhere else
 *   node tool/build-web.mjs --base /app/      where it will be served from (/app/, as the relay serves it)
 *   node tool/build-web.mjs --hub <wss://…>   the hub it speaks to (none: the one beside the page, /hub where it is /app/)
 *   node tool/build-web.mjs --no-calls        without calls. Every build has them otherwise (GMFB-30, GMFB-51; since
 *                                             2026-11-25, when --calls was needed for them): the page's own WebRTC joins
 *                                             spaces' calls and friends' and groups' calls (lib/sms.dart browserCalls)
 *   node tool/build-web.mjs --no-files        without Files spaces. Every build has them otherwise (GMFB-30): a circle's
 *                                             files listed, uploaded, downloaded and shown in the page (lib/sms.dart
 *                                             browserFiles). --calls and --files are still taken, and change nothing
 *
 *   dart run relay/bin/relay.dart --web build/web      then: http://127.0.0.1:8787/app/
 *   node tool/web/e2e.mjs                               two people using it, in Chromium and WebKit
 *
 * WHAT IT DOES
 *   1. Holds the page in web/ to what it must say (`flutter test test/web_build_test.dart`: its policy, its files,
 *      app.gogho.st's headers, the extension's pin of the Argon2id it carries). Not one of the release guards: a
 *      phone's or a computer's release doesn't wait on the web page (tool/lib/guards.mjs).
 *   2. Holds web/argon2id.js, as committed, to test/vectors/argon2id.json, every time (tool/web/check-argon2.mjs); and
 *      checks it is what tool/web/build-argon2.mjs builds, where the extension's packages are installed.
 *   3. `flutter build web -t lib/web/main.dart`, with:
 *        --no-web-resources-cdn   Flutter's engine (CanvasKit) from the build's own folder, not from www.gstatic.com
 *        --csp                    no code made from text at run time, so the page's own policy can forbid it
 *        --pwa-strategy=none      no service worker (web/flutter_bootstrap.js sets none up)
 *        --base-href              where the page is served from
 *        --dart-define=GHOST_WEB_HUB   the hub, where one is named (lib/web/app.dart: hubFor)
 *        --dart-define=GHOST_WEB_CALLS=false  with --no-calls (lib/web/app.dart: webCalls, true where nothing says)
 *        --dart-define=GHOST_WEB_FILES=false  with --no-files (lib/web/app.dart: webFiles, true where nothing says)
 *      and, where a hub is named, the page's policy lets it speak to that one too (connect-src), and send there the
 *      feedback, a report where the hub is Uplink's own, and a Files space's files (tool/lib/web_site.mjs
 *      connectFor).
 *   4. Takes the four emoji sets off the list of fonts a browser loads before its first frame (eleven megabytes):
 *      the app fetches the one in use when it starts, and another when it is chosen (lib/web/emoji.dart). The files
 *      stay in the build.
 *   5. Puts the fonts the engine asks for when a letter is in none of the app's own (Chinese, Arabic, Devanagari,
 *      mathematics, …) beside the page, as fallback-fonts/, where tool/web/fallback-fonts.mjs --fetch has brought them
 *      here; says so where it hasn't, and such letters are drawn as boxes.
 *   6. Names main.dart.js by what is in it (main.dart.<hash>.js) and has the loader ask for that name: the relay
 *      lets a browser keep such a file for a year, and asks again for everything else.
 *   7. Packs every file a browser would unpack (.js, .wasm, .json, fonts) beside itself as .br and .gz, which the
 *      relay sends in the file's place to a browser that reads them.
 *   8. Says what a first visit fetches, and how big.
 *
 * NOTHING IS FETCHED FROM ANYONE ELSE by the page this builds: no engine from Google, no fonts from Google, no
 * analytics, no scripts but its own. web/index.html's policy says so to the browser, and tool/web/e2e.mjs fails if
 * the page asks any address but its own and its hub.
 */
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { brotliCompressSync, constants, gzipSync } from 'node:zlib';
import { APP_HUB, connectFor, goodHub, pageWithHub, policyOf } from './lib/web_site.mjs';
import { checkArgon2 } from './web/check-argon2.mjs';
import { engineFonts, fontsDir, present } from './web/fallback-fonts.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const option = (name, fallback) => {
  const at = args.indexOf(`--${name}`);
  return at >= 0 && at + 1 < args.length ? args[at + 1] : fallback;
};
const fail = (words) => {
  console.error(`build-web: ${words}`);
  process.exit(1);
};
// The build for app.gogho.st: served from its own address's top, speaking to gogho.st's hub.
const forApp = args.includes('--app');
const out = resolve(option('out', join(ROOT, 'build', forApp ? 'web-app' : 'web')));
const profile = args.includes('--profile');
const base = option('base', forApp ? '/' : '/app/');
const hub = option('hub', forApp ? APP_HUB : '');
// Calls and Files spaces are in every build unless left out (GMFB-30: the full web client).
const withCalls = !args.includes('--no-calls');
const withFiles = !args.includes('--no-files');
if (!base.startsWith('/') || !base.endsWith('/')) fail(`--base starts and ends with a slash (${base}).`);
if (hub && !goodHub(hub)) fail(`--hub is a wss:// address with a path (or ws:// to this computer, for a try here): ${hub}`);

// 1. The page, before anything is built.
const pageTest = spawnSync('flutter', ['test', 'test/web_build_test.dart'], { cwd: ROOT, stdio: 'inherit' });
if (pageTest.status !== 0) fail('test/web_build_test.dart failed: the page in web/, or app.gogho.st\'s block, is not what it must be. Nothing was built.');

// 2. The one file of JavaScript the app carries beside itself.
try {
  const { count, slowest } = checkArgon2(ROOT);
  console.log(`web/argon2id.js gives all ${count} vectors (the slowest in ${slowest} ms here).`);
} catch (e) {
  fail(`${e.message} Nothing was built.`);
}
if (existsSync(join(ROOT, 'extension', 'node_modules', '@noble', 'hashes'))) {
  const checked = spawnSync('node', [join(ROOT, 'tool', 'web', 'build-argon2.mjs'), '--check'], { cwd: ROOT, stdio: 'inherit' });
  if (checked.status !== 0) fail('web/argon2id.js is not what its script builds. Run node tool/web/build-argon2.mjs and commit the file.');
} else {
  console.log('web/argon2id.js not checked against its script: the extension\'s packages are not installed (npm ci in extension/). Its answers are checked above all the same.');
}

// 3. The app.
const version = /^version:\s*(\S+?)\+(\d+)/m.exec(readFileSync(join(ROOT, 'pubspec.yaml'), 'utf8'));
const built = spawnSync(
  'flutter',
  ['build', 'web', '-t', 'lib/web/main.dart', profile ? '--profile' : '--release', '--no-web-resources-cdn', '--csp', '--pwa-strategy=none', '--no-wasm-dry-run', `--base-href=${base}`, ...(hub ? [`--dart-define=GHOST_WEB_HUB=${hub}`] : []), `--dart-define=GHOST_WEB_CALLS=${withCalls}`, `--dart-define=GHOST_WEB_FILES=${withFiles}`, '-o', out],
  { cwd: ROOT, stdio: 'inherit' },
);
if (built.status !== 0) fail('flutter build web failed.');
for (const needed of ['index.html', 'main.dart.js', 'flutter_bootstrap.js', 'argon2id.js', 'assets/FontManifest.json', 'canvaskit/canvaskit.wasm']) {
  if (!existsSync(join(out, needed))) fail(`the build has no ${needed}.`);
}
// The hub named: the page's policy lets it speak to that one, beside its own address, and send there what it sends
// over plain HTTP (feedback, and a report where the hub is Uplink's own: tool/lib/web_site.mjs sentBeside),
// and nothing else.
if (hub) {
  const pagePath = join(out, 'index.html');
  const page = pageWithHub(readFileSync(pagePath, 'utf8'), hub);
  writeFileSync(pagePath, page);
  const said = policyOf(page).split(';').map((p) => p.trim()).find((p) => p.startsWith('connect-src '));
  if (said !== connectFor(hub)) fail(`the built page's policy says ${said}, not ${connectFor(hub)}.`);
}

// What a build before this one left beside the files: packed copies and a main.dart.js by another name.
const walk = (dir) => readdirSync(dir, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(join(dir, e.name)) : [join(dir, e.name)]));
for (const file of walk(out)) {
  if (/\.(br|gz)$/.test(file) || /^main\.dart\.[0-9a-f]{8,}\.js$/.test(relative(out, file))) rmSync(file);
}
rmSync(join(out, 'fallback-fonts'), { recursive: true, force: true });

// 4. The emoji sets: in the build, off the list of what is loaded before the first frame.
const manifestPath = join(out, 'assets', 'FontManifest.json');
const families = JSON.parse(readFileSync(manifestPath, 'utf8'));
const emoji = families.filter((f) => f.family.startsWith('Ghost Emoji '));
if (emoji.length !== 4) fail(`expected the four emoji sets in the font list, found ${emoji.length}: lib/emoji_sets.dart and pubspec.yaml have changed, and lib/web/emoji.dart with this script must follow.`);
for (const f of emoji) {
  for (const font of f.fonts) {
    if (!existsSync(join(out, 'assets', font.asset))) fail(`the build has no ${font.asset}.`);
  }
}
if (!families.some((f) => f.family === 'Roboto')) fail('the font list has no Roboto of the build\'s own: Flutter would fetch it from Google.');
writeFileSync(manifestPath, JSON.stringify(families.filter((f) => !emoji.includes(f))));

// 5. The fonts the engine asks for when a letter is in none of the app's own (web/flutter_bootstrap.js: beside the
// page), where they have been brought here (tool/web/fallback-fonts.mjs --fetch), with their licence.
const fallback = (() => {
  const dir = fontsDir(ROOT);
  let wanted;
  try {
    wanted = engineFonts();
  } catch (e) {
    return `not put beside the page: ${e.message}`;
  }
  const { have, missing } = present(wanted, dir);
  if (missing.length || !existsSync(join(dir, 'OFL.txt'))) {
    return `not put beside the page: ${missing.length} of the ${wanted.length} the engine names are not in ${relative(ROOT, dir)}${existsSync(join(dir, 'OFL.txt')) ? '' : ', nor their licence (OFL.txt)'}. Letters outside the app's own fonts (Chinese, Japanese, Korean, Arabic, Devanagari, mathematics, …) are drawn as boxes. node tool/web/fallback-fonts.mjs --fetch brings them, once.`;
  }
  for (const p of have) {
    mkdirSync(dirname(join(out, 'fallback-fonts', p)), { recursive: true });
    copyFileSync(join(dir, p), join(out, 'fallback-fonts', p));
  }
  copyFileSync(join(dir, 'OFL.txt'), join(out, 'fallback-fonts', 'OFL.txt'));
  return `beside the page: all ${have.length} the engine names, in fallback-fonts/, with their licence.`;
})();

// 6. The app's JavaScript, named by what is in it.
const mainPath = join(out, 'main.dart.js');
const hash = createHash('sha256').update(readFileSync(mainPath)).digest('hex').slice(0, 16);
const named = `main.dart.${hash}.js`;
renameSync(mainPath, join(out, named));
const bootstrapPath = join(out, 'flutter_bootstrap.js');
const bootstrap = readFileSync(bootstrapPath, 'utf8');
if (bootstrap.split('"mainJsPath":"main.dart.js"').length !== 2) fail('flutter_bootstrap.js does not name main.dart.js once, as it did: Flutter\'s loader has changed.');
if (bootstrap.includes('gstatic.com') && !bootstrap.includes('"useLocalCanvasKit":true')) fail('flutter_bootstrap.js would fetch the engine from Google.');
writeFileSync(bootstrapPath, bootstrap.replace('"mainJsPath":"main.dart.js"', `"mainJsPath":"${named}"`));
// Source maps of a profile build name the file they belong to; a release build has none.
if (existsSync(`${mainPath}.map`)) renameSync(`${mainPath}.map`, join(out, `${named}.map`));

// 7. Packed beforehand, for the relay to send as they are.
const packable = /\.(js|mjs|wasm|json|html|css|ttf|otf|svg|map|txt|bin|frag)$|\/NOTICES$/;
const sizes = new Map();
for (const file of walk(out)) {
  const name = relative(out, file).split('\\').join('/');
  const bytes = readFileSync(file);
  let br = null;
  if (packable.test(`/${name}`) && bytes.length >= 1024) {
    br = brotliCompressSync(bytes, { params: { [constants.BROTLI_PARAM_QUALITY]: 11, [constants.BROTLI_PARAM_SIZE_HINT]: bytes.length } });
    const gz = gzipSync(bytes, { level: 9 });
    // Only where packing gains something: a font of pictures doesn't.
    if (br.length < bytes.length * 0.95) {
      writeFileSync(`${file}.br`, br);
      writeFileSync(`${file}.gz`, gz);
    } else {
      br = null;
    }
  }
  sizes.set(name, { raw: bytes.length, sent: br ? br.length : bytes.length });
}

// 8. How big.
const mb = (n) => `${(n / 1048576).toFixed(2)} MB`;
const kb = (n) => (n >= 1048576 ? mb(n) : `${(n / 1024).toFixed(0)} KB`);
const show = (name) => {
  const s = sizes.get(name);
  return s ? `${kb(s.raw).padStart(9)}  ${kb(s.sent).padStart(9)} sent  ${name}` : `        ?  ${name}`;
};
const kept = JSON.parse(readFileSync(manifestPath, 'utf8')).flatMap((f) => f.fonts.map((x) => `assets/${x.asset}`));
// What a browser asks for to draw the first screen: the page, the loader, the app, the engine (Chromium's build of
// it; other browsers take canvaskit/canvaskit.wasm, a little bigger), the fonts on the list, and the emoji set in use.
const first = ['index.html', 'flutter_bootstrap.js', named, 'canvaskit/chromium/canvaskit.js', 'canvaskit/chromium/canvaskit.wasm', 'assets/AssetManifest.bin.json', 'assets/FontManifest.json', ...kept, 'assets/assets/css/ink.css', 'assets/assets/css/app.css', 'assets/assets/art/ghost-mark.png'].filter((n) => sizes.has(n));
const emojiInUse = 'assets/assets/emoji/NotoColor.ttf';
const sum = (names, key) => names.reduce((n, name) => n + (sizes.get(name)?.[key] ?? 0), 0);
const all = [...sizes.keys()];
console.log(`\nGhost Messaging for a browser${version ? ` ${version[1]} (${version[2]})` : ''}, ${profile ? 'profile' : 'release'}, to be served from ${base}${forApp ? ' of app.gogho.st' : ''}, speaking to ${hub || 'the hub beside it'}, ${withCalls ? 'with calls' : 'without calls (--no-calls)'}, ${withFiles ? 'with Files spaces' : 'without Files spaces (--no-files)'}: ${out}`);
console.log(`  the app's JavaScript   ${show(named)}`);
console.log(`  Argon2id, as a worker  ${show('argon2id.js')}`);
console.log('  a first visit fetches, before the first screen:');
for (const name of first) console.log(`    ${show(name)}`);
console.log(`    ${kb(sum(first, 'raw')).padStart(9)}  ${kb(sum(first, 'sent')).padStart(9)} sent  in all, ${first.length} files`);
console.log(`  then the emoji set in use (Noto where none was chosen):\n    ${show(emojiInUse)}`);
console.log(`  the whole folder: ${mb(sum(all, 'raw'))} in ${all.length} files (every engine variant, every emoji set, stickers, sounds), fetched only as wanted.`);
console.log(`  not on the font list any more: ${emoji.map((f) => f.family).join(', ')}.`);
console.log(`  the fonts for letters outside the app's own: ${fallback}`);
if (forApp) {
  console.log(`\nShip it to app.gogho.st: node tool/deploy-site.mjs --app ${relative(process.cwd(), out) || '.'} --print first, to see what it does.`);
} else {
  console.log(`\nServe it: dart run relay/bin/relay.dart --web ${relative(process.cwd(), out) || '.'}    Try it: node tool/web/e2e.mjs${out === join(ROOT, 'build', 'web') ? '' : ` --web ${out}`}${withCalls ? '' : ' --no-calls'}${withFiles ? '' : ' --no-files'}`);
}
