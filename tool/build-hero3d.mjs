#!/usr/bin/env node
/**
 * Builds the hero's 3D phone for the site: site-src/hero3d/main.js and what it imports, with three.js, into the one
 * file the landing page loads, site/hero3d.js; and writes the app's views that lie on the phone's screens
 * (site-src/hero3d/views/*.html) into site/index.html, between its H3 marks.
 *
 *   node tool/build-hero3d.mjs            build
 *   node tool/build-hero3d.mjs --check    fail if site/hero3d.js is not what the source builds to
 *
 * three.js (MIT) and esbuild are fetched from npm into build/hero3d/ (which git ignores) at the versions pinned
 * here, the first time and whenever a version changes. Nothing else is fetched, and the page loads nothing from
 * anywhere but the site itself.
 */
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const THREE = '0.187.0', ESBUILD = '0.25.10';
const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const work = join(root, 'build', 'hero3d');
const out = join(root, 'site', 'hero3d.js');

mkdirSync(work, { recursive: true });
const have = (name, version) => {
  try { return JSON.parse(readFileSync(join(work, 'node_modules', name, 'package.json'), 'utf8')).version === version; } catch { return false; }
};
if (!have('three', THREE) || !have('esbuild', ESBUILD)) {
  if (!existsSync(join(work, 'package.json'))) writeFileSync(join(work, 'package.json'), '{"private":true,"name":"hero3d-build","type":"module"}\n');
  execFileSync('npm', ['install', '--no-audit', '--no-fund', '--save-exact', `three@${THREE}`, `esbuild@${ESBUILD}`], { cwd: work, stdio: 'inherit' });
}

const esbuild = await import(pathToFileURL(join(work, 'node_modules', 'esbuild', 'lib', 'main.js')).href);
const result = await esbuild.build({
  entryPoints: [join(root, 'site-src', 'hero3d', 'main.js')],
  bundle: true,
  format: 'esm',
  minify: true,
  target: ['es2020'],
  legalComments: 'none',
  nodePaths: [join(work, 'node_modules')],
  write: false,
  banner: { js: `/* Uplink's hero phone. Built by tool/build-hero3d.mjs from site-src/hero3d; edit that, not this. Includes three.js r${THREE.split('.')[1]} (https://threejs.org), MIT licence: /hero3d.licence.txt */` },
});
const built = result.outputFiles[0].text;

// The app's views on the phone's screens: each file of site-src/hero3d/views holds the panes of one view (a pane is
// one screen's worth: `<div class="gm h3-pane" data-screen="cover|inner-l|inner-r" ...>` at the start of a line),
// and the landing page holds every screen's panes between that screen's H3 marks.
const VIEWS = ['thread', 'plugins', 'space'];
const panes = { cover: [], 'inner-l': [], 'inner-r': [] };
for (const view of VIEWS) {
  const file = join(root, 'site-src', 'hero3d', 'views', view + '.html');
  if (!existsSync(file)) { console.warn(`no view ${view} yet (site-src/hero3d/views/${view}.html)`); continue; }
  const text = readFileSync(file, 'utf8').replace(/<!--[\s\S]*?-->\n?/g, '');
  const starts = [...text.matchAll(/^<div class="gm h3-pane"[^>]*data-screen="([^"]+)"/gm)];
  starts.forEach((m, i) => {
    if (!panes[m[1]]) throw new Error(`${view}: no screen called ${m[1]}`);
    panes[m[1]].push(text.slice(m.index, i + 1 < starts.length ? starts[i + 1].index : text.length).trimEnd());
  });
}
const pagePath = join(root, 'site', 'index.html');
let page = readFileSync(pagePath, 'utf8');
for (const [screen, list] of Object.entries(panes)) {
  const open = `<!-- H3:${screen} -->\n`, close = `<!-- /H3:${screen} -->`;
  const a = page.indexOf(open), b = page.indexOf(close);
  if (a < 0 || b < a) throw new Error(`site/index.html has no H3:${screen} marks`);
  page = page.slice(0, a + open.length) + list.map((p) => p + '\n').join('') + page.slice(b);
}

// three.js's licence goes with it, as the licence asks.
const licencePath = join(root, 'site', 'hero3d.licence.txt');
const licence = `site/hero3d.js includes three.js ${THREE} (https://threejs.org), under this licence:\n\n` + readFileSync(join(work, 'node_modules', 'three', 'LICENSE'), 'utf8');

if (process.argv.includes('--check')) {
  let ok = true;
  if (!existsSync(licencePath) || readFileSync(licencePath, 'utf8') !== licence) { console.error('site/hero3d.licence.txt is not three.js\'s licence as pinned'); ok = false; }
  if (!existsSync(out) || readFileSync(out, 'utf8') !== built) { console.error('site/hero3d.js is not what site-src/hero3d builds to'); ok = false; }
  if (readFileSync(pagePath, 'utf8') !== page) { console.error("site/index.html's H3 views are not those of site-src/hero3d/views"); ok = false; }
  if (!ok) { console.error('run node tool/build-hero3d.mjs'); process.exit(1); }
  console.log('site/hero3d.js and the views in site/index.html are current');
} else {
  writeFileSync(out, built);
  writeFileSync(licencePath, licence);
  writeFileSync(pagePath, page);
  console.log(`site/hero3d.js: ${(built.length / 1024).toFixed(0)} KB; views: ${Object.entries(panes).map(([k, v]) => `${k} ${v.length}`).join(', ')}`);
}
