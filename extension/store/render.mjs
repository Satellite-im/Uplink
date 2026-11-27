#!/usr/bin/env node
// Renders the Chrome Web Store promo images from store/promo-src/*.html to store/promo/*.png, at exactly the sizes
// the store wants. Uses headless Google Chrome at 2x for crisp text, then downscales with ImageMagick.
//
//   node store/render.mjs
//
// Needs Google Chrome and ImageMagick (`magick`). The 128 icon is copied from icons/128.png.
import { execFileSync } from 'node:child_process';
import { cpSync, mkdirSync, rmSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const SRC = join(here, 'promo-src');
const OUT = join(here, 'promo');
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const SCALE = 2;

const shots = [
  { name: 'screenshot', w: 1280, h: 800 },
  { name: 'tile', w: 440, h: 280 },
];

mkdirSync(OUT, { recursive: true });
cpSync(join(here, '..', 'icons', '128.png'), join(OUT, 'icon-128.png'));
console.log('icon-128.png  <- icons/128.png');

for (const { name, w, h } of shots) {
  const big = join(OUT, `.${name}.2x.png`);
  execFileSync(CHROME, [
    '--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-sandbox',
    `--force-device-scale-factor=${SCALE}`,
    `--window-size=${w},${h}`,
    '--virtual-time-budget=2500',
    `--screenshot=${big}`,
    `file://${join(SRC, `${name}.html`)}`,
  ], { stdio: ['ignore', 'ignore', 'inherit'] });
  const out = join(OUT, `${name}-${w}x${h}.png`);
  execFileSync('magick', [big, '-resize', `${w}x${h}`, '-strip', out]);
  rmSync(big, { force: true });
  console.log(`${name}-${w}x${h}.png`);
}
console.log('done.');
