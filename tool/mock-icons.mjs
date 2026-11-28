// Writes site/mock/icons.svg: the app's own icons (lib/art/lucide.g.dart, lib/art/lucide_more.dart: Phosphor's
// duotone paths on its 256 grid, under Lucide's names) as one sprite of <symbol>s for the website's HTML mocks of
// the app (site/mock/mock.css). The body is the wash, a fifth of the ink as the app paints it (icon_wash.dart
// phosphorWash), the outline the ink; `--gm-wash: 0` on an icon drops the wash (AppIcon's wash: false).
//
//   node tool/mock-icons.mjs            the names below
//   node tool/mock-icons.mjs a b c      those names added to them
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const names = new Set([
  'arrow-left', 'arrow-up', 'phone', 'phone-call', 'phone-off', 'settings', 'search', 'check', 'check-check',
  'brush-cleaning', 'message-circle', 'message-square', 'message-square-plus', 'key-round', 'headphones',
  'headphone-off', 'funnel', 'list-filter', 'x', 'triangle-alert', 'pin', 'lock', 'contact-round', 'archive', 'plus',
  'sticker', 'mic', 'mic-off', 'video', 'video-off', 'chevron-up', 'chevron-down', 'chevron-right', 'chevron-left',
  'link', 'shield-check', 'users', 'user-round', 'user-plus', 'calendar-plus', 'volume-2', 'volume-x',
  'waves-horizontal', 'audio-lines', 'music', 'sliders-horizontal', 'send', 'image', 'file', 'file-text', 'smile',
  'reply', 'copy', 'ellipsis', 'trash-2', 'bell', 'globe', 'screen-share', 'sparkles', 'map-pin', 'circle-check',
  'smartphone', 'laptop', 'monitor', 'download', 'play', 'pause', 'minimize', 'maximize',
  // The feature walkthroughs' own (site/mock/features.js): files and folders, a recording, a shared window, captions.
  'folder', 'folder-open', 'folder-input', 'film', 'hard-drive-upload', 'circle-dot', 'circle-stop', 'type',
  'refresh-cw', 'app-window', 'share-2',
  ...process.argv.slice(2),
]);

const icons = new Map();
for (const file of ['lib/art/lucide.g.dart', 'lib/art/lucide_more.dart']) {
  const src = readFileSync(join(root, file), 'utf8');
  for (const m of src.matchAll(/LucideIcon\.phosphor\('([a-z0-9-]+)',\s*'([^']*)',\s*'([^']*)'\)/g)) {
    if (!icons.has(m[1])) icons.set(m[1], { body: m[2], outline: m[3] });
  }
}

const out = ['<svg xmlns="http://www.w3.org/2000/svg" style="display:none">'];
const missing = [];
for (const name of [...names].sort()) {
  const icon = icons.get(name);
  if (!icon) { missing.push(name); continue; }
  out.push(`<symbol id="${name}" viewBox="0 0 256 256">` +
    (icon.body ? `<path d="${icon.body}" style="opacity:var(--gm-wash,.2)"/>` : '') +
    `<path d="${icon.outline}"/></symbol>`);
}
out.push('</svg>\n');
const target = join(root, 'site/mock/icons.svg');
mkdirSync(dirname(target), { recursive: true });
writeFileSync(target, out.join('\n'));
console.log(`${names.size - missing.length} icons -> site/mock/icons.svg` + (missing.length ? `; not in the app: ${missing.join(', ')}` : ''));
