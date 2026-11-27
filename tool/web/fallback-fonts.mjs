#!/usr/bin/env node
/**
 * The fonts Flutter's engine asks for when a letter isn't in any of the app's own fonts (Chinese, Japanese, Korean,
 * Arabic, Devanagari, mathematics and some 150 more scripts): Google's Noto, cut into pieces the engine fetches one at
 * a time as letters need them. web/flutter_bootstrap.js has the engine ask for them beside the page
 * (`fallback-fonts/`), never of fonts.gstatic.com, so the app's own address must have them, or such letters are drawn
 * as boxes and each miss is a 404 there.
 *
 *   node tool/web/fallback-fonts.mjs            says which the engine in use names, and how many are here
 *   node tool/web/fallback-fonts.mjs --fetch    fetches the missing ones from fonts.gstatic.com, ONCE, into
 *                                               build/fallback-fonts, and writes their SHA-256s beside them
 *
 * tool/build-web.mjs copies them into the build (fallback-fonts/) where every one the engine names is here, and says
 * where they aren't. The list is the engine's own (bin/cache/flutter_web_sdk/.../font_fallback_data.dart in the
 * Flutter SDK), so a newer Flutter names other files, and they are fetched again.
 *
 * WHAT THIS ASKS OF GOOGLE: the files, at build time, from this computer; never from a visitor's browser. The fonts are
 * under the SIL Open Font License 1.1, which lets them be served from anywhere with the licence beside them: its text
 * goes in build/fallback-fonts/OFL.txt (put there by hand, once), and build-web.mjs serves the fonts only with it.
 * Nothing is fetched unless --fetch is given.
 */
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, renameSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

/** Where they are kept between builds: outside what git keeps, as every build's output is. */
export const fontsDir = (root = ROOT) => join(root, 'build', 'fallback-fonts');

/** The Flutter SDK the app is built with: where `flutter` is, its links followed. */
function flutterRoot() {
  const flutter = execFileSync('which', ['flutter'], { encoding: 'utf8' }).trim();
  const real = execFileSync('python3', ['-c', 'import os,sys;print(os.path.realpath(sys.argv[1]))', flutter], { encoding: 'utf8' }).trim();
  return resolve(dirname(real), '..');
}

/** Every file the engine in use may ask for, as the paths it asks for them by (`notosanssc/v37/….woff2`). */
export function engineFonts() {
  const data = join(flutterRoot(), 'bin', 'cache', 'flutter_web_sdk', 'lib', '_engine', 'engine', 'font_fallback_data.dart');
  if (!existsSync(data)) throw new Error(`the engine's font list is not at ${data}: run flutter precache --web.`);
  const paths = [...readFileSync(data, 'utf8').matchAll(/'([a-z0-9]+\/v\d+\/[A-Za-z0-9_.-]+\.(?:woff2|ttf|otf))'/g)].map((m) => m[1]);
  if (paths.length < 100) throw new Error(`the engine's font list names only ${paths.length} files: Flutter's has changed, and this must follow.`);
  return [...new Set(paths)];
}

/** Which of [paths] are in [dir] and match the SHA-256 written when they were fetched. */
export function present(paths, dir = fontsDir()) {
  let sums = {};
  try {
    sums = JSON.parse(readFileSync(join(dir, 'sha256.json'), 'utf8'));
  } catch {}
  const have = [], missing = [];
  for (const p of paths) {
    const file = join(dir, p);
    const ok = existsSync(file) && sums[p] && createHash('sha256').update(readFileSync(file)).digest('hex') === sums[p];
    (ok ? have : missing).push(p);
  }
  return { have, missing };
}

/**
 * Fetches each of [paths] that [dir] does not hold yet from fonts.gstatic.com, checks it is a font, and writes its
 * SHA-256 beside the rest (every fifty, so a run cut short keeps what it has). How many were fetched, and their bytes.
 */
async function fetchAll(paths, dir) {
  mkdirSync(dir, { recursive: true });
  let sums = {};
  try {
    sums = JSON.parse(readFileSync(join(dir, 'sha256.json'), 'utf8'));
  } catch {}
  const { missing } = present(paths, dir);
  let bytes = 0, done = 0;
  for (const p of missing) {
    const response = await fetch(`https://fonts.gstatic.com/s/${p}`, { redirect: 'error' });
    if (!response.ok) throw new Error(`fonts.gstatic.com answered ${response.status} for ${p}`);
    const body = Buffer.from(await response.arrayBuffer());
    // A font file and nothing else: woff2 starts wOF2, a TrueType font 0x00010000 or 'true', an OpenType one 'OTTO'.
    const magic = body.subarray(0, 4).toString('latin1');
    if (!['wOF2', 'OTTO', 'true', '\u0000\u0001\u0000\u0000'].includes(magic)) throw new Error(`${p} is not a font file`);
    const file = join(dir, p);
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(`${file}.part`, body);
    renameSync(`${file}.part`, file);
    sums[p] = createHash('sha256').update(body).digest('hex');
    bytes += body.length;
    done++;
    if (done % 50 === 0) {
      writeFileSync(join(dir, 'sha256.json'), JSON.stringify(sums, null, 1));
      console.log(`  ${done} of ${missing.length}`);
    }
  }
  writeFileSync(join(dir, 'sha256.json'), JSON.stringify(sums, null, 1));
  return { done, bytes };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const paths = engineFonts();
  const dir = fontsDir();
  if (process.argv.includes('--fetch')) {
    console.log(`Fetching the engine's fallback fonts from fonts.gstatic.com into ${dir}…`);
    const { done, bytes } = await fetchAll(paths, dir);
    console.log(`${done} fetched (${(bytes / 1048576).toFixed(1)} MB).`);
  }
  const { have, missing } = present(paths, dir);
  const size = have.reduce((n, p) => n + statSync(join(dir, p)).size, 0);
  console.log(`The engine names ${paths.length} fallback fonts; ${have.length} are in ${dir} (${(size / 1048576).toFixed(1)} MB), ${missing.length} are not.${missing.length ? ' node tool/web/fallback-fonts.mjs --fetch fetches them.' : ''}`);
  // Their licence goes beside them wherever they are served: the SIL Open Font License 1.1's own text, as any Noto
  // release carries it (OFL.txt). Put there by hand, once: tool/build-web.mjs serves none of them without it.
  if (!existsSync(join(dir, 'OFL.txt'))) console.log(`Their licence is not in ${join(dir, 'OFL.txt')}: put the SIL Open Font License 1.1's text there (any Noto release has it as OFL.txt), and tool/build-web.mjs serves them with it.`);
}
