#!/usr/bin/env node
/**
 * The browser's half of integration_test/recording_video_native_test.dart (GMFB-42): a Chromium with stand-in devices
 * (a tone for a microphone, a moving pattern for a camera) that opens the page the Mac app's test serves and sends it
 * a voice, a camera and a second picture over WebRTC, until the page says the recording is made.
 *
 *   node tool/voicebench/video_peer.mjs [port]      before or after the test is started: it waits for the page
 *
 * Playwright is found as tool/web/e2e.mjs finds it: GHOST_PLAYWRIGHT, else npm's npx cache.
 */
import { existsSync, readdirSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

const port = Number(process.argv[2] || 47931);

function findPlaywright() {
  if (process.env.GHOST_PLAYWRIGHT) return process.env.GHOST_PLAYWRIGHT;
  const cache = join(homedir(), '.npm', '_npx');
  if (existsSync(cache)) {
    for (const dir of readdirSync(cache)) {
      const at = join(cache, dir, 'node_modules', 'playwright', 'index.mjs');
      if (existsSync(at)) return at;
    }
  }
  console.error('video_peer: Playwright was not found. `npx playwright install chromium`, or set GHOST_PLAYWRIGHT.');
  process.exit(2);
}

const { chromium } = await import(pathToFileURL(findPlaywright()).href);
const url = `http://127.0.0.1:${port}/`;

// The page is there once the test's app is built and started: up to a quarter of an hour.
const until = Date.now() + 15 * 60 * 1000;
for (;;) {
  try {
    if ((await fetch(url)).ok) break;
  } catch {}
  if (Date.now() > until) {
    console.error('video_peer: no page at ' + url);
    process.exit(1);
  }
  await new Promise((d) => setTimeout(d, 1000));
}

const browser = await chromium.launch({
  args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream', '--autoplay-policy=no-user-gesture-required'],
});
const page = await browser.newPage();
page.on('console', (m) => console.log('video_peer page:', m.text()));
await page.goto(url);
console.log('video_peer: sending');
await page.waitForFunction(() => document.title === 'done', null, { timeout: 5 * 60 * 1000 }).catch(() => {});
await browser.close();
console.log('video_peer: done');
