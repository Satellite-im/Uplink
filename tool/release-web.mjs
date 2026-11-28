#!/usr/bin/env node
/**
 * Builds Uplink for a browser and publishes it at gogho.st/app (GMFB-30, "Full web client"), so the web client
 * follows the app's releases instead of being deployed by hand. tool/release.mjs runs it after a release is live
 * (--no-web there leaves it out); it can be run by itself as well, as the chain's other scripts are.
 *
 *   node tool/release-web.mjs [--keep-connection]
 *                                        build (tool/build-web.mjs --app --base /app/ --hub wss://gogho.st/hub, into
 *                                        build/web-app) and ship it with the site (tool/deploy-site.mjs --app
 *                                        build/web-app), as gogho.st/app was first deployed on 2026-11-23
 *   node tool/release-web.mjs --no-deploy   the build alone, nothing sent
 *   node tool/release-web.mjs --no-build    ship build/web-app as it is (built before, by this or by hand)
 *   node tool/release-web.mjs --print       the build, then what the box would run (deploy-site.mjs --print); nothing sent
 *   node tool/release-web.mjs --no-calls / --no-files   a build without calls or without Files spaces (tool/build-web.mjs)
 *
 * The build has calls and Files spaces, as every web build does since 2026-11-25. deploy-site.mjs checks the folder
 * before anything is sent (served from /app/, gogho.st's hub, the page's policy the block's), ships the site's files
 * with it in one ssh session (one login, none where --keep-connection left one open), and asks the page as a visitor
 * would afterwards. Caddy's blocks are not touched here: the one for /app/ is there already (--caddy, run once).
 */
import { spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { APP_HUB } from './lib/web_site.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const OUT = join(ROOT, 'build', 'web-app');
// gogho.st/app (Matt, 2026-11-23: chosen over waiting for app.gogho.st's DNS record), speaking to gogho.st's hub.
const BASE = '/app/';
const args = process.argv.slice(2);
const has = (name) => args.includes(`--${name}`);
const option = (name) => {
  const at = args.indexOf(`--${name}`);
  return at >= 0 && at + 1 < args.length ? args[at + 1] : null;
};
const fail = (why) => {
  console.error(`x release-web: ${why}`);
  process.exit(1);
};
const run = (script, scriptArgs) => {
  console.log(`> node ${script} ${scriptArgs.join(' ')}`);
  const result = spawnSync('node', [join(ROOT, script), ...scriptArgs], { cwd: ROOT, stdio: 'inherit' });
  if (result.error) fail(`${script} could not run: ${result.error.message}`);
  if (result.status !== 0) fail(`${script} failed (${result.status}).`);
};

if (!has('no-build')) {
  run('tool/build-web.mjs', ['--app', '--base', BASE, '--hub', APP_HUB, '--out', OUT, ...(has('no-calls') ? ['--no-calls'] : []), ...(has('no-files') ? ['--no-files'] : [])]);
}
if (!existsSync(join(OUT, 'index.html'))) fail(`no build in ${OUT}: run it without --no-build.`);
if (!readFileSync(join(OUT, 'index.html'), 'utf8').includes(`<base href="${BASE}">`)) fail(`${OUT} was not built to be served from ${BASE}: run it without --no-build.`);
if (has('no-deploy')) {
  console.log(`ok the web client is built in ${OUT}; nothing was sent (--no-deploy).`);
  process.exit(0);
}
run('tool/deploy-site.mjs', ['--app', OUT, ...(has('keep-connection') ? ['--keep-connection'] : []), ...(has('print') ? ['--print'] : [])]);
if (!has('print')) console.log(`ok the web client is live: https://gogho.st${BASE}`);
