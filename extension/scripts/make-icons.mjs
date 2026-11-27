#!/usr/bin/env node
// Writes simple placeholder icons (icons/16.png, 48.png, 128.png): a dark rounded square with a pale ghost mark.
// The build copies whatever is in icons/, and since 2026-11-27 that is the app's own mark, written there by the app's
// tool/app_icon.py: running this would put the placeholders back over it.
import { deflateSync } from 'node:zlib';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const iconsDir = join(here, '..', 'icons');
mkdirSync(iconsDir, { recursive: true });

const INK = [22, 22, 26];
const PALE = [243, 243, 244];

const crcTable = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();
function crc32(buf) {
  let c = ~0;
  for (let i = 0; i < buf.length; i++) c = crcTable[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return ~c >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body), 0);
  return Buffer.concat([len, body, crc]);
}
function png(size, pixels) {
  const sig = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // RGBA
  const raw = Buffer.alloc(size * (size * 4 + 1));
  for (let y = 0; y < size; y++) {
    raw[y * (size * 4 + 1)] = 0; // filter: none
    for (let x = 0; x < size; x++) {
      const [r, g, b, a] = pixels(x, y);
      const o = y * (size * 4 + 1) + 1 + x * 4;
      raw[o] = r;
      raw[o + 1] = g;
      raw[o + 2] = b;
      raw[o + 3] = a;
    }
  }
  return Buffer.concat([sig, chunk('IHDR', ihdr), chunk('IDAT', deflateSync(raw, { level: 9 })), chunk('IEND', Buffer.alloc(0))]);
}

function draw(size) {
  const r = size * 0.18; // corner radius
  const inRound = (x, y) => {
    const cx = Math.min(Math.max(x, r), size - r);
    const cy = Math.min(Math.max(y, r), size - r);
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r || (x >= r && x <= size - r) || (y >= r && y <= size - r);
  };
  // Uplink body: a circle head with a flat-ish bottom, two eyes.
  const hx = size / 2;
  const hy = size * 0.46;
  const hr = size * 0.26;
  const eye = size * 0.045;
  return png(size, (x, y) => {
    if (!inRound(x + 0.5, y + 0.5)) return [0, 0, 0, 0];
    const dHead = (x - hx) ** 2 + (y - hy) ** 2 <= hr * hr;
    const inBody = x > hx - hr && x < hx + hr && y >= hy && y < size * 0.78;
    let pale = dHead || inBody;
    // scalloped bottom
    if (inBody && y > size * 0.66) {
      const wave = Math.sin(((x - (hx - hr)) / (hr * 0.5)) * Math.PI);
      if (y > size * 0.70 + wave * size * 0.05) pale = false;
    }
    if (pale) {
      const leftEye = (x - (hx - hr * 0.42)) ** 2 + (y - hy) ** 2 <= eye * eye;
      const rightEye = (x - (hx + hr * 0.42)) ** 2 + (y - hy) ** 2 <= eye * eye;
      if (leftEye || rightEye) return [...INK, 255];
      return [...PALE, 255];
    }
    return [...INK, 255];
  });
}

for (const size of [16, 48, 128]) {
  writeFileSync(join(iconsDir, `${size}.png`), draw(size));
  console.log(`icons/${size}.png`);
}
