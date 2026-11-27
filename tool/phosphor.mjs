#!/usr/bin/env node
// The app's icons are Phosphor's duotone set (Matt, 2026-11-20: "switch to using phosphor icons"; Duotone, app and
// docs). The code still names each icon by its Lucide name (Lucide.search, LucideMore.qrCode, 'search' in the docs'
// pages), and tool/phosphor-map.json says which Phosphor icon draws it. This rewrites every
// `LucideIcon('name', [...], [...])` in lib/ (and any already made) as
// `LucideIcon.phosphor('name', '<duotone body>', '<outline>')`, both paths on Phosphor's 256 grid.
//
//   node tool/phosphor.mjs            rewrite (fetches @phosphor-icons/core into build/phosphor first, if missing)
//   node tool/phosphor.mjs --check    exit 1 if anything would change
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const VERSION = '2.1.1';
const PKG = join(ROOT, 'build/phosphor/package');
const check = process.argv.includes('--check');

if (!existsSync(join(PKG, 'assets/duotone'))) {
  mkdirSync(join(ROOT, 'build/phosphor'), { recursive: true });
  const tgz = execFileSync('npm', ['pack', '-q', `@phosphor-icons/core@${VERSION}`], { cwd: join(ROOT, 'build/phosphor'), encoding: 'utf8' }).trim().split('\n').pop();
  execFileSync('tar', ['xzf', tgz], { cwd: join(ROOT, 'build/phosphor') });
}

const map = JSON.parse(readFileSync(join(ROOT, 'tool/phosphor-map.json'), 'utf8'));
// The Phosphor icon that draws the Lucide [name], as two path strings: the duotone's faint body (the paths at
// opacity 0.2, '' where it has none) and its outline.
function duotone(name) {
  const p = map[name];
  if (!p) throw new Error(`No Phosphor icon for "${name}": add it to tool/phosphor-map.json`);
  const svg = readFileSync(join(PKG, 'assets/duotone', `${p}-duotone.svg`), 'utf8');
  const paths = [...svg.matchAll(/<path d="([^"]+)"( opacity="0\.2")?\/>/g)];
  const body = paths.filter((x) => x[2]).map((x) => x[1]).join(' ');
  const line = paths.filter((x) => !x[2]).map((x) => x[1]).join(' ');
  if (!line) throw new Error(`${p}: no outline`);
  return [body, line];
}

// Finds `LucideIcon(` or `LucideIcon.phosphor(` and the `)` that closes it, minding strings and brackets.
function rewrite(text) {
  let out = '', at = 0;
  const re = /LucideIcon(?:\.phosphor)?\(\s*'([a-z0-9-]+)'/g;
  for (let m; (m = re.exec(text)); ) {
    let i = m.index + 'LucideIcon'.length, depth = 0, quote = null;
    for (; i < text.length; i++) {
      const c = text[i];
      if (quote) { if (c === '\\') i++; else if (c === quote) quote = null; continue; }
      if (c === "'" || c === '"') quote = c;
      else if (c === '(' || c === '[') depth++;
      else if (c === ')' || c === ']') { depth--; if (depth === 0) break; }
    }
    const [body, line] = duotone(m[1]);
    out += text.slice(at, m.index) + `LucideIcon.phosphor('${m[1]}', '${body}', '${line}')`;
    at = i + 1;
    re.lastIndex = at;
  }
  return out + text.slice(at);
}

// Every Dart file under [dir] but app_icon.dart, which is left as it is.
function* dartFiles(dir) {
  for (const f of readdirSync(dir)) {
    const p = join(dir, f);
    if (statSync(p).isDirectory()) yield* dartFiles(p);
    else if (f.endsWith('.dart') && f !== 'app_icon.dart') yield p;
  }
}
let changed = [];
for (const f of dartFiles(join(ROOT, 'lib'))) {
  const text = readFileSync(f, 'utf8');
  if (!/LucideIcon(\.phosphor)?\('/.test(text)) continue;
  const next = rewrite(text);
  if (next !== text) { changed.push(f.slice(ROOT.length + 1)); if (!check) writeFileSync(f, next); }
}
if (check && changed.length) { console.error(`x icons not Phosphor's: ${changed.join(', ')} (run node tool/phosphor.mjs)`); process.exit(1); }
console.log(changed.length ? `ok ${changed.length} files drawn with Phosphor duotone ${VERSION}: ${changed.join(', ')}` : 'ok every icon is Phosphor\'s');
