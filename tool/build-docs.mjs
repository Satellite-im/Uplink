#!/usr/bin/env node
/**
 * Builds gogho.st/docs (Matt, 2026-11-19: "Spend time creating a /docs/ page on ghost messaging ... use glacier UI for it
 * not the ghost marketing site style, just use the marketing sites color scheme. Please use real mocked elements not
 * screenshots to give users guidance on steps").
 *
 *   node tool/build-docs.mjs          docs-src/ into site/docs/ (written whole each time; commit what it writes)
 *   node tool/build-docs.mjs --check  fails if site/docs/ is not what docs-src/ makes (for a test)
 *
 * WHAT IT READS
 *   docs-src/pages.mjs         the sections and their pages, in order: what the sidebar, search and prev/next follow.
 *                              Two books, each with a sidebar and a search of its own: the docs (`sections`, at /docs/)
 *                              and the developer docs (`developer`, at /docs/developer/), never listed among each other
 *   docs-src/pages/<slug>.html each page's body: plain HTML with the mock tags below, `<h2 id>` for its outline
 *   docs-src/docs.css, docs.js the frame's style and behaviour (theme, sidebar, search, outline)
 *   packages/glacier/assets/css/tokens.css  Glacier's own tokens, copied so the mocks are drawn with the app's sizes
 *   lib/art/lucide.g.dart, lib/art/lucide_more.dart  the app's icons (Phosphor duotone): only those a page uses go in the sprite
 *   examples/plugins/*.ghostplugin  the example plugins, copied byte for byte into site/docs/examples/ (below)
 *   docs-src/api/app-methods.json    the app's API as its own registry describes it (test/api_reference_test.dart writes it)
 *   docs-src/api/relay-routes.mjs    the relay server's HTTP routes, by hand from relay/lib (a route added there is added here)
 *
 * WHAT ELSE IT WRITES
 *   site/docs/api/ghost-messaging.postman_collection.json  both APIs as a Postman collection (v2.1), from the two above
 *
 * THE MOCK TAGS are the app's own pieces drawn in HTML, never pictures of it (so they read in both themes, at any
 * width, and stay true when a label changes in one place). Each expands to plain HTML here; nothing runs in the page.
 * They are expanded inside <pre><code> too, so a page escapes <, > and & there by hand.
 *   <m-screen title back caption wide actions="icon,icon">…</m-screen>   a phone's (or, wide, a computer's) screen
 *     rail="messages|circle|new|contacts|archive|marketplace|settings" circles="Name:hue|…" open="Name" railtap="id or Name"
 *                                                                        the rail down its left: Home, the circles, the rest
 *   <m-section title foot>…</m-section>                                  a settings group: a card of rows
 *   <m-row icon hue label hint value chev switch=on|off tap danger/>      a settings row
 *   <m-btn kind=primary|secondary|ghost|danger icon tap>Label</m-btn>     a button
 *   <m-dock active tap/>                                                 the dock: new, messages, contacts, archive, marketplace, settings
 *   <m-tabs items="A|B|C" active tap/>                                   a segmented toggle
 *   <m-convo name preview time unread mark tap/>                         a conversation's row
 *   <m-bubble from=me|them name time>words</m-bubble>                     a message
 *   <m-menu title>…<m-item icon tap danger>Label</m-item>…</m-menu>       a menu or sheet of choices
 *   <m-field label placeholder value/>                                   a text field
 *   <m-area label placeholder value/>                                    a field of several lines
 *   <m-upload label hint icon tap/>                                      a picture well with its label (an icon, a screenshot)
 *   <m-chips items="A|B|C" on="A|C" tap="B"/>                            chips, some chosen (a plugin's tags)
 *   <m-status kind=submitted|in_review|changes_requested|approved|rejected|withdrawn|superseded>Words</m-status>
 *                                                                        a submission's status capsule
 *   <m-plugin name icon hue line by reviewed dev added tap=card|add/>    a plugin's card on a Marketplace shelf: its tile,
 *                                                                        name, line, "By @x" with the Reviewed mark or
 *                                                                        "In development", and Add or Added at its end
 *   <m-tri label on=deny|inherit|allow tap=…/>                          a space's three-way permission
 * An open space (docs-src/pages/open-spaces.html; places and sizes in percent of the floor, see openSpaceTags):
 *   <m-floor walls="far left right near" hint say newgroup dock h ratio inset caption>…</m-floor>
 *                                                                        the floor from above: its dots, the walls in view,
 *                                                                        the hint, the chat's box, New group, the call's controls
 *   <m-standing name hue x y talking muted heard you ring mark/>          a person where they stand: picture, ripple, name,
 *                                                                        as faint as heard; `you` with the hearing ring
 *   <m-group name hue x y r count mine tap>…bubbles…</m-group>           a group's circle and name, bubbles over it
 *   <m-floor-bubbles side x y>…</m-floor-bubbles>  <m-floor-bubble name you seen>words</m-floor-bubble>
 *                                                                        the chat's bubbles at the floor's side, or anywhere
 *   <m-screen … full>  a computer's screen with the rail wide enough for a list and a pane beside it
 *   <m-words/>  <m-qr/>  <m-code value/>  <m-switch on/>  <m-avatar name hue/>  <m-space kind name line unread/>
 *                                                                        (a space's row; kind voice, text, files, sms or open)
 *   <steps><step title>…</step></steps>   numbered steps        <note kind=tip|warn|alpha|soon title>…</note>
 *   <ui>Settings › Me</ui>  a place in the app                 <soon/>  a Coming soon badge
 *   <icon-names/>  every icon name a plugin may use, read from lib/art/lucide.g.dart
 *   <example-file name="bills"/>  an example plugin's whole file, from examples/plugins
 *   <api-methods/>  every method of the app's API: what it takes, what it answers, a call to try
 *   <relay-routes group="market"/>  one group of the relay's HTTP routes, the same way
 * `tap` puts the ring that says "press here" on a piece.
 */
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const SRC = join(ROOT, 'docs-src');
const OUT = join(ROOT, 'site/docs');
const check = process.argv.includes('--check');

const { sections, developer } = await import(pathToFileURL(join(SRC, 'pages.mjs')).href);
// The two books. A page knows its book, so its sidebar, its previous and next, and its search stay inside it.
const books = [
  { name: 'Docs', home: '/docs/', search: 'search.json', sections, other: { href: '/docs/developer/', label: 'Developer docs' } },
  { name: 'Developer docs', home: '/docs/developer/', search: 'developer/search.json', sections: developer, other: { href: '/docs/', label: 'Back to the docs' } },
];
for (const b of books) b.pages = b.sections.flatMap((s) => s.pages.map((p) => ({ ...p, section: s.title, book: b })));
const pages = books.flatMap((b) => b.pages);

// --- icons: the app's own, Phosphor's duotone under their Lucide names (tool/phosphor.mjs) ----------------------------

const icons = new Map();
for (const f of ['lib/art/lucide.g.dart', 'lib/art/lucide_more.dart']) {
  const p = join(ROOT, f);
  if (!existsSync(p)) continue;
  for (const m of readFileSync(p, 'utf8').matchAll(/LucideIcon\.phosphor\('([a-z0-9-]+)',\s*'([^']*)',\s*'([^']*)'\)/g)) {
    if (!icons.has(m[1])) icons.set(m[1], { body: m[2], outline: m[3] });
  }
}
const used = new Set();
function icon(name, cls = 'i') {
  if (!name) return '';
  if (!icons.has(name)) throw new Error(`No icon "${name}" in the app's icon set`);
  used.add(name);
  return `<svg class="${cls}" aria-hidden="true"><use href="/docs/icons.svg#${name}"/></svg>`;
}
function sprite() {
  const out = [...used].sort().map((n) => {
    const { body, outline } = icons.get(n);
    // The body at a fifth of the ink, as Phosphor's duotone draws it, and the outline in the whole ink.
    return `<symbol id="${n}" viewBox="0 0 256 256"><g fill="currentColor">${body ? `<path d="${body}" opacity=".2"/>` : ''}<path d="${outline}"/></g></symbol>`;
  });
  return `<svg xmlns="http://www.w3.org/2000/svg">${out.join('')}</svg>\n`;
}

// --- the mock tags ------------------------------------------------------------------------------------------------------

const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
function attrs(text) {
  const a = {};
  for (const m of text.matchAll(/([a-z][a-z0-9-]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>/]+)))?/g)) a[m[1]] = m[2] ?? m[3] ?? m[4] ?? true;
  return a;
}
const tap = (a) => (a.tap ? ' tap' : '');
const HUES = ['blue', 'teal', 'green', 'amber', 'orange', 'coral', 'rose', 'purple', 'indigo', 'slate', 'cyan', 'mint'];
const hueOf = (s) => HUES[[...String(s)].reduce((h, c) => (h * 31 + c.charCodeAt(0)) >>> 0, 7) % HUES.length];

// The rail (lib/ui/nav_rail.dart): Home at its head, each circle as its face (a halo in its colour round the one open,
// as the app draws it since 0.10.0), a circled plus to start or join one, and New, Contacts, Archive, Marketplace and
// Settings at its foot. The Marketplace ring is the store between Archive and Settings (Matt, 2026-11-20: "Move plugins
// out of settings into a marketplace button on the navigation rail with a marketplace icon").
function rail(a) {
  const ring = (id, ic, label) => `<span class="m-ring${a.rail === id ? ' on' : ''}${a.railtap === id ? ' tap' : ''}" title="${label}">${icon(ic)}</span>`;
  const circles = String(a.circles ?? '').split('|').filter(Boolean).map((c) => {
    const [name, hue] = c.split(':');
    const initials = name.split(/\s+/).map((w) => w[0]).join('').slice(0, 2).toUpperCase();
    return `<span class="m-rail-circle${a.open === name ? ' open' : ''}" title="${esc(name)}"><span class="m-avatar${a.railtap === name ? ' tap' : ''}" data-hue="${hue ?? hueOf(name)}">${esc(initials)}</span></span>`;
  }).join('');
  return `<div class="m-rail" role="img" aria-label="The rail: Messages, your circles, New, Contacts, Archive, Marketplace, Settings">${ring('messages', 'message-square', 'Messages')}<span class="m-rail-rule"></span>${circles}${ring('add-circle', 'circle-plus', 'New or join a circle')}<span class="m-rail-gap"></span><span class="m-rail-rule"></span>${ring('new', 'plus', 'New')}${ring('contacts', 'contact-round', 'Contacts')}${ring('archive', 'archive', 'Archive')}${ring('marketplace', 'store', 'Marketplace')}${ring('settings', 'settings', 'Settings')}</div>`;
}

// Every icon name a plugin may give (docs-src/pages/plugin-format.html): the keys of the app's Lucide.all, read from
// lib/art/lucide.g.dart so the list is always the app's own, less the three the app keeps for itself (ghost, its own
// mark; store, the Marketplace's ring; shield-check, "Can't reach the internet").
function iconNames() {
  const src = readFileSync(join(ROOT, 'lib/art/lucide.g.dart'), 'utf8');
  const at = src.indexOf('static const Map<String, LucideIcon> all = {');
  if (at < 0) throw new Error('No Lucide.all in lib/art/lucide.g.dart');
  const names = [...src.slice(at, src.indexOf('};', at)).matchAll(/^\s*'([a-z0-9-]+)':/gm)].map((m) => m[1]);
  return names.filter((n) => !['ghost', 'store', 'shield-check'].includes(n));
}

// A plugin's tile, as the Marketplace's shelves draw one (lib/ui/plugins_page): a white glyph on its hue's gradient.
const tile = (a) => `<span class="m-tile" data-hue="${a.hue ?? hueOf(a.name ?? a.icon ?? '?')}">${icon(a.icon ?? 'puzzle')}</span>`;

// A submission's status, in My submissions' words (lib/ui/market/my_submissions.dart).
const STATUSES = ['submitted', 'in_review', 'changes_requested', 'approved', 'rejected', 'withdrawn', 'superseded'];

// An open space's floor and what stands on it, as lib/ui/open_space_view.dart draws them (Matt, 2026-11-23: "please add
// docs with components from open spaces that explains how they work"). Everything on a floor is placed by percentages
// of the floor's box (x across from its left, y down from its top), so a mock reads the same at a phone's width and a
// computer's. Sizes (a circle's radius, the hearing ring's) are percentages of the floor's width, as CSS draws them.
function openSpaceTags() {
  const num = (v, fallback, what) => {
    const n = Number(v ?? fallback);
    if (!Number.isFinite(n)) throw new Error(`${what} "${v}" is not a number`);
    return n;
  };
  const place = (a, tag) => `left:${num(a.x, 50, `${tag} x`)}%;top:${num(a.y, 50, `${tag} y`)}%`;
  const letters = (name) => esc(String(name).split(/\s+/).map((w) => w[0]).join('').slice(0, 2).toUpperCase());
  const WALLS = ['far', 'left', 'right', 'near'];
  // The call's controls (lib/ui/voice_screen.dart's CallDock): Mute and Deafen as pills with their device chevrons,
  // the camera, Share screen, and Leave in red.
  const callDock = () =>
    `<div class="m-calldock" role="img" aria-label="The call's controls: Mute, Deafen, camera, Share screen, Leave"><span class="m-cpill">${icon('mic')}${icon('chevron-up', 'i m-cchev')}</span><span class="m-cpill">${icon('headphones')}${icon('chevron-up', 'i m-cchev')}</span><span class="m-cbtn">${icon('video-off')}</span><span class="m-cbtn">${icon('screen-share')}</span><span class="m-cbtn leave">${icon('phone-off')}</span></div>`;
  return {
    // The floor seen from above: its dots, the walls that are in view (`walls="far left right near"`: the view stops
    // at a wall, so a wall in view is at the view's edge), the hint at its head, the chat's box and New group at its
    // foot, and the call's controls over the foot (`dock`). `inset` leaves out the figure round it (inside a screen).
    'm-floor': (a, inner) => {
      const walls = String(a.walls ?? '').split(/[\s,]+/).filter(Boolean);
      for (const w of walls) if (!WALLS.includes(w)) throw new Error(`m-floor wall "${w}" is not one of ${WALLS.join(', ')}`);
      const cls = ['m-floor', ...walls.map((w) => `w-${w}`), a.dock ? 'has-dock' : '', a.wide ? 'wide' : ''].filter(Boolean).join(' ');
      const style = [a.h ? `height:${a.h}` : '', a.ratio ? `aspect-ratio:${a.ratio}` : ''].filter(Boolean).join(';');
      const hint = a.hint ? `<span class="m-fpill m-fhint${a.hintfade ? ' fading' : ''}">${esc(a.hint)}</span>` : '';
      const say = a.say ? `<span class="m-fsay${a.say === 'tap' ? ' tap' : ''}">Say something</span>` : '';
      const group = a.newgroup ? `<span class="m-fpill m-fnew${a.newgroup === 'tap' ? ' tap' : ''}">${icon('target')}New group</span>` : '';
      const floor = `<div class="${cls}"${style ? ` style="${style}"` : ''} role="group" aria-label="${esc(a.label ?? 'An open space\'s floor, seen from above')}">${walls.map((w) => `<span class="m-wall ${w}"></span>`).join('')}${inner}${hint}${say}${group}${a.dock ? callDock() : ''}</div>`;
      return a.inset ? floor : `<figure class="mock m-floor-mock${a.wide ? ' wide' : ''}">${floor}${a.caption ? `<figcaption>${esc(a.caption)}</figcaption>` : ''}</figure>`;
    },
    // A person where they stand: their picture, the ripple while they talk (`talking`, or how loud, 0 to 1), their name
    // under it with a crossed microphone while `muted`, and as faint as the app draws them for how much of them is
    // heard (`heard`, 0 to 1: 0.4 + 0.6 of it). `you` is this device, with the ring of how far it hears (`ring`, its
    // radius in percent of the floor's width). `mark` adds the docs' own label of how much of them is heard (never the
    // app's): `mark` alone says the percentage, `mark="words"` says those.
    'm-standing': (a) => {
      const you = Boolean(a.you);
      const name = you ? 'You' : String(a.name ?? '?');
      const heard = you ? 1 : Math.min(1, Math.max(0, num(a.heard, 1, 'm-standing heard')));
      const level = a.talking === true ? 0.6 : Math.min(1, Math.max(0, num(a.talking, 0, 'm-standing talking')));
      const ring = you && a.ring !== 'none' ? `<span class="m-hearing" style="${place(a, 'm-standing')};width:${2 * num(a.ring, 40, 'm-standing ring')}%" aria-hidden="true"></span>` : '';
      const label = a.mark === true ? `${Math.round(heard * 100)}%` : a.mark;
      const mark = a.mark ? `<span class="m-heardmark${heard === 0 ? ' none' : ''}">${icon(heard === 0 ? 'volume-x' : 'volume-2')}${esc(label)}</span>` : '';
      const talk = level > 0 ? ` talking" style="--lv:${level}` : '';
      return `${ring}<div class="m-standing${you ? ' you' : ''}" style="${place(a, 'm-standing')};--seen:${(0.4 + 0.6 * heard).toFixed(2)}"><span class="m-face${talk}" data-hue="${a.hue ?? hueOf(name)}">${letters(a.name ?? name)}</span><span class="m-tag">${esc(name)}${a.muted ? icon('mic-off', 'i m-tagmute') : ''}</span>${mark}</div>`;
    },
    // A group: its circle (`r`, its radius in percent of the floor's width; `mine` while this device stands in it) and its
    // name over it with how many are in it (`count`). Between its tags, the chat's bubbles over it.
    'm-group': (a, inner) => {
      const hue = a.hue ?? 'purple';
      const stack = inner && inner.trim() ? `<div class="m-fstack over">${inner}</div>` : '';
      return `<div class="m-group${a.mine ? ' mine' : ''}" data-hue="${hue}" style="${place(a, 'm-group')};width:${2 * num(a.r, 14, 'm-group r')}%"><span class="m-gname${a.tap ? ' tap' : ''}"><b>${esc(a.name ?? 'Group')}</b><span>${esc(a.count ?? '0')}</span></span>${stack}</div>`;
    },
    // The chat's bubbles at the side of the floor, oldest at the top (`side`), or anywhere by x and y.
    'm-floor-bubbles': (a, inner) => `<div class="m-fstack${a.side ? ' side' : ''}"${a.side ? '' : ` style="${place(a, 'm-floor-bubbles')}"`}>${inner}</div>`,
    // One bubble: the writer's name (`you`: You) and their words, as strongly drawn as `seen` says (0.08 to 1; 1, whole).
    'm-floor-bubble': (a, inner) => `<div class="m-fbubble" style="opacity:${Math.min(1, Math.max(0.08, num(a.seen, 1, 'm-floor-bubble seen')))}"><b>${a.you ? 'You' : esc(a.name ?? '?')}</b> ${inner}</div>`,
  };
}

const render = {
  'm-screen': (a, inner) => {
    const actions = String(a.actions ?? '').split(',').filter(Boolean).map((n) => `<span class="m-iconbtn">${icon(n.trim())}</span>`).join('');
    const head = a.title === undefined && !a.back ? '' : `<div class="m-head">${a.back ? `<span class="m-iconbtn">${icon('arrow-left')}</span>` : ''}<span class="m-title">${esc(a.title ?? '')}</span>${actions}</div>`;
    const main = `${head}<div class="m-body">${inner}</div>`;
    const screen = a.rail === undefined ? `<div class="m-screen">${main}</div>` : `<div class="m-screen has-rail">${rail(a)}<div class="m-main">${main}</div></div>`;
    return `<figure class="mock${a.wide ? ' wide' : ''}${a.full ? ' full' : ''}">${screen}${a.caption ? `<figcaption>${esc(a.caption)}</figcaption>` : ''}</figure>`;
  },
  'm-section': (a, inner) => `<div class="m-section">${a.title ? `<div class="m-section-title">${esc(a.title)}</div>` : ''}<div class="m-card">${inner}</div>${a.foot ? `<p class="m-foot">${esc(a.foot)}</p>` : ''}</div>`,
  'm-row': (a) => {
    const end = a.switch ? `<span class="m-switch${a.switch === 'on' ? ' on' : ''}"></span>` : (a.value ? `<span class="m-value">${esc(a.value)}</span>` : '') + (a.chev ? icon('chevron-right', 'i m-chev') : '');
    return `<div class="m-row${tap(a)}${a.danger ? ' danger' : ''}">${a.icon ? `<span class="m-ico" data-hue="${a.hue ?? hueOf(a.label ?? a.icon)}">${icon(a.icon)}</span>` : ''}<span class="m-txt"><b>${esc(a.label ?? '')}</b>${a.hint ? `<small>${esc(a.hint)}</small>` : ''}</span>${end ? `<span class="m-end">${end}</span>` : ''}</div>`;
  },
  'm-btn': (a, inner) => `<span class="m-btn ${a.kind ?? 'secondary'}${tap(a)}">${a.icon ? icon(a.icon) : ''}${inner ? `<span>${inner}</span>` : ''}</span>`,
  'm-dock': (a) => {
    const ring = [['new', 'plus', 'New'], ['messages', 'message-circle', 'Messages'], ['contacts', 'contact-round', 'Contacts'], ['archive', 'archive', 'Archive'], ['marketplace', 'store', 'Marketplace'], ['settings', 'settings', 'Settings']];
    return `<div class="m-dock" role="img" aria-label="The dock: New, Messages, Contacts, Archive, Marketplace, Settings">${ring.map(([id, ic, label]) => `<span class="m-ring${a.active === id ? ' on' : ''}${a.tap === id ? ' tap' : ''}" title="${label}">${icon(ic)}</span>`).join('')}</div>`;
  },
  'm-tabs': (a) => `<div class="m-tabs">${String(a.items).split('|').map((t) => `<span class="${t === a.active ? 'on' : ''}${t === a.tap ? ' tap' : ''}">${esc(t)}</span>`).join('')}</div>`,
  'm-convo': (a) => `<div class="m-convo${tap(a)}">${render['m-avatar']({ name: a.name, hue: a.hue })}<span class="m-txt"><b>${esc(a.name)}</b><small>${esc(a.preview ?? '')}</small></span><span class="m-end"><small>${esc(a.time ?? '')}</small>${a.unread ? `<span class="m-count">${esc(a.unread)}</span>` : ''}</span></div>`,
  'm-bubble': (a, inner) => `<div class="m-msg ${a.from === 'me' ? 'me' : 'them'}">${a.name ? `<small class="m-name">${esc(a.name)}</small>` : ''}<span class="m-bubble">${inner}</span>${a.time ? `<small class="m-time">${esc(a.time)}</small>` : ''}</div>`,
  'm-menu': (a, inner) => `<div class="m-menu">${a.title ? `<div class="m-menu-title">${esc(a.title)}</div>` : ''}${inner}</div>`,
  'm-item': (a, inner) => `<div class="m-item${tap(a)}${a.danger ? ' danger' : ''}">${a.icon ? icon(a.icon) : ''}<span>${inner}</span>${a.hint ? `<small>${esc(a.hint)}</small>` : ''}</div>`,
  'm-field': (a) => `<label class="m-field">${a.label ? `<span>${esc(a.label)}</span>` : ''}<span class="m-input${a.value ? '' : ' empty'}${tap(a)}">${esc(a.value ?? a.placeholder ?? '')}</span></label>`,
  // A field of several lines (a description, notes for the reviewer): as a field, taller, keeping its line breaks.
  'm-area': (a) => `<label class="m-field">${a.label ? `<span>${esc(a.label)}</span>` : ''}<span class="m-input m-area${a.value ? '' : ' empty'}${tap(a)}">${esc(a.value ?? a.placeholder ?? '')}</span></label>`,
  // A picture to choose (a plugin's icon, a screenshot): a dashed well with its mark, the label above, a hint beside.
  'm-upload': (a) => `<div class="m-field">${a.label ? `<span>${esc(a.label)}</span>` : ''}<span class="m-upload"><span class="m-well${tap(a)}">${icon(a.icon ?? 'image-plus')}</span>${a.hint ? `<small>${esc(a.hint)}</small>` : ''}</span></div>`,
  // Chips, as the Marketplace's shelves and the submission form's tags draw them; `on` the chosen ones.
  'm-chips': (a) => {
    const on = new Set(String(a.on ?? '').split('|').filter(Boolean));
    return `<div class="m-chips">${String(a.items ?? '').split('|').filter(Boolean).map((c) => `<span class="m-chip${on.has(c) ? ' on' : ''}${a.tap === c ? ' tap' : ''}">${on.has(c) ? icon('check') : ''}${esc(c)}</span>`).join('')}</div>`;
  },
  'm-status': (a, inner) => {
    if (!STATUSES.includes(a.kind)) throw new Error(`m-status kind "${a.kind}" is not one of ${STATUSES.join(', ')}`);
    return `<span class="m-status" data-kind="${a.kind}">${inner}</span>`;
  },
  // A plugin's card on a shelf (lib/ui/plugins_page/plugins_page.dart): who made one from another developer, with the
  // Reviewed mark, or In development for one loaded in Developer mode, so the two never look alike (Matt, 2026-11-20:
  // "I'd like to be able to verify them for the store through a review process").
  'm-plugin': (a) => {
    const by = a.by ? `By @${esc(a.by)}` : '';
    const mark = a.reviewed ? `<span class="m-reviewed">${icon('badge-check')}Reviewed</span>` : a.dev ? '<span class="m-devtag">In development</span>' : '';
    const source = by || mark ? `<span class="m-source">${by}${by && mark ? ' · ' : ''}${mark}</span>` : '';
    const button = `<span class="m-add${a.added ? ' on' : ''}${a.tap === 'add' ? ' tap' : ''}">${a.added ? `${icon('check')}Added` : 'Add'}</span>`;
    return `<div class="m-plugin${a.tap === true || a.tap === 'card' ? ' tap' : ''}">${tile(a)}<span class="m-txt"><b>${esc(a.name ?? '')}</b>${a.line ? `<small>${esc(a.line)}</small>` : ''}${source}</span>${button}</div>`;
  },
  'm-switch': (a) => `<span class="m-switch${a.on ? ' on' : ''}${tap(a)}"></span>`,
  'm-avatar': (a) => `<span class="m-avatar" data-hue="${a.hue ?? hueOf(a.name ?? '?')}">${esc(String(a.name ?? '?').split(/\s+/).map((w) => w[0]).join('').slice(0, 2).toUpperCase())}</span>`,
  'm-space': (a) => {
    const ic = { voice: 'headphones', text: 'message-circle', files: 'folder', sms: 'smartphone', open: 'compass' }[a.kind ?? 'text'];
    const hue = { voice: 'green', text: 'blue', files: 'amber', sms: 'orange', open: 'purple' }[a.kind ?? 'text'];
    return `<div class="m-spacerow${tap(a)}"><span class="m-ico" data-hue="${hue}">${icon(ic)}</span><span class="m-txt"><b>${esc(a.name)}</b>${a.line ? `<small>${esc(a.line)}</small>` : ''}</span>${a.unread ? `<span class="m-count">${esc(a.unread)}</span>` : ''}</div>`;
  },
  ...openSpaceTags(),
  'm-words': () => {
    const words = ['orbit', 'lantern', 'velvet', 'canyon', 'mosaic', 'ripple', 'harbor', 'ember', 'quartz', 'meadow', 'tundra', 'falcon'];
    return `<ol class="m-words">${words.map((w) => `<li>${w}</li>`).join('')}</ol>`;
  },
  'm-qr': (a) => {
    // A stand-in, not a working code: a fixed pattern with the three finder squares.
    let s = 0x2f6b1a9;
    const cells = [];
    for (let y = 0; y < 21; y++) for (let x = 0; x < 21; x++) {
      const finder = (x < 7 && y < 7) || (x > 13 && y < 7) || (x < 7 && y > 13);
      if (finder) continue;
      s = (s * 1103515245 + 12345) >>> 0;
      if ((s >> 16) & 1) cells.push(`<rect x="${x}" y="${y}" width="1" height="1"/>`);
    }
    const finder = (x, y) => `<rect x="${x}" y="${y}" width="7" height="7"/><rect x="${x + 1}" y="${y + 1}" width="5" height="5" class="q0"/><rect x="${x + 2}" y="${y + 2}" width="3" height="3"/>`;
    return `<span class="m-qr${tap(a)}" role="img" aria-label="A QR code"><svg viewBox="-2 -2 25 25">${finder(0, 0)}${finder(14, 0)}${finder(0, 14)}${cells.join('')}</svg></span>`;
  },
  'm-code': (a) => `<span class="m-code">${[...String(a.value ?? '482913').replace(/\s/g, '')].map((c) => `<span>${esc(c)}</span>`).join('')}</span>`,
  'm-banner': (a, inner) => `<div class="m-banner">${inner}</div>`,
  'm-sheet': (a, inner) => `<div class="m-sheet">${a.title ? `<div class="m-sheet-title">${esc(a.title)}</div>` : ''}${inner}</div>`,
  // A three-way permission (Deny / As the circle says / Allow), its name above it.
  'm-tri': (a) => `<div class="m-tri"><b>${esc(a.label)}</b><div class="m-tabs">${[['deny', 'Deny'], ['inherit', 'As the circle says'], ['allow', 'Allow']].map(([v, t]) => `<span class="${a.on === v ? 'on' : ''}${a.tap === v ? ' tap' : ''}">${t}</span>`).join('')}</div></div>`,
  'm-p': (a, inner) => `<p class="m-p">${inner}</p>`,
  'm-row-raw': (a, inner) => `<div class="m-row m-raw${tap(a)}">${inner}</div>`,
  steps: (a, inner) => `<ol class="steps">${inner}</ol>`,
  step: (a, inner) => `<li class="step"><div class="step-body">${a.title ? `<h3>${esc(a.title)}</h3>` : ''}${inner}</div></li>`,
  note: (a, inner) => {
    const kind = a.kind ?? 'tip';
    const ic = { tip: 'lightbulb', warn: 'triangle-alert', alpha: 'flask-conical', soon: 'clock', info: 'info' }[kind] ?? 'info';
    const title = a.title ?? { tip: 'Tip', warn: 'Good to know', alpha: 'In the alpha', soon: 'Coming soon', info: 'Note' }[kind];
    return `<aside class="note ${kind}">${icon(ic)}<div><b>${esc(title)}</b>${inner}</div></aside>`;
  },
  ui: (a, inner) => `<span class="ui-path">${inner}</span>`,
  soon: () => `<span class="badge soon">Coming soon</span>`,
  'icon-names': () => `<p class="icon-names">${iconNames().map((n) => `<code>${n}</code>`).join(' ')}</p>`,
  // An example plugin's whole file (examples/plugins/<name>.ghostplugin), read as it is, so the page never drifts from it.
  'example-file': (a) => `<pre><code>${readFileSync(join(ROOT, 'examples/plugins', `${a.name}.ghostplugin`), 'utf8').trimEnd().replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')}</code></pre>`,
};

// --- the API reference -------------------------------------------------------------------------------------------------
// The docs' reference and the Postman collection are made from the same two lists, so they can't say different things.

const appApi = JSON.parse(readFileSync(join(SRC, 'api/app-methods.json'), 'utf8'));
const relayApi = (await import(pathToFileURL(join(SRC, 'api/relay-routes.mjs')).href)).groups;
const code = (s) => `<code>${esc(s)}</code>`;
const pre = (s) => `<pre><code>${String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')}</code></pre>`;
const paramTable = (head, rows) => (rows.length ? `<table class="api-params"><tr>${head.map((h) => `<th>${h}</th>`).join('')}</tr>${rows.map((r) => `<tr>${r.map((c) => `<td>${c}</td>`).join('')}</tr>`).join('')}</table>` : '');

// One method of the app's API: its name (the link others point at), what it does, its parameters and a call to copy.
function appMethod(m) {
  const rows = m.params.map((p) => [code(p.name), esc(p.type), p.required ? 'yes' : '', esc(p.doc)]);
  const body = m.example ? ` \\\n  -d '${JSON.stringify(m.example)}'` : '';
  return `<section class="api-m" id="${m.name}"><h4>${code(m.name)}${m.danger ? ' <span class="badge danger" title="Changes or removes something">changes things</span>' : ''}</h4><p>${esc(m.summary)}</p>${paramTable(['Parameter', 'Type', 'Needed', 'What'], rows)}<p class="api-ret"><b>Answers</b> ${code(m.returns)}</p>${pre(`curl -s http://localhost:8765/api/${m.name} -H 'Authorization: Bearer <token>'${body}`)}</section>`;
}
render['api-methods'] = () => {
  const groups = [...new Set(appApi.methods.map((m) => m.group))];
  return groups.map((g) => `<h3 id="group-${g}">${esc(g)}</h3>${appApi.methods.filter((m) => m.group === g).map(appMethod).join('')}`).join('');
};

// One route of the relay server (docs-src/api/relay-routes.mjs says what each field is).
function relayRoute(r) {
  const rows = (r.params ?? []).map((p) => [code(p.name), esc(p.in), p.required ? 'yes' : '', esc(p.doc)]);
  return `<section class="api-m" id="${r.id}"><h4><span class="verb ${r.method.toLowerCase()}">${r.method}</span> ${code(r.path)}</h4><p>${esc(r.summary)}</p><p class="api-ret"><b>Who</b> ${esc(r.who)}</p>${paramTable(['Field', 'Where', 'Needed', 'What'], rows)}${r.answers ? `<p class="api-ret"><b>Answers</b> ${code(r.answers)}</p>` : ''}${r.errors ? `<p class="api-ret"><b>Refusals</b> ${r.errors.map(code).join(' ')}</p>` : ''}</section>`;
}
render['relay-routes'] = (a) => {
  const g = relayApi.find((x) => x.id === a.group);
  if (!g) throw new Error(`No group "${a.group}" in docs-src/api/relay-routes.mjs`);
  return g.routes.map(relayRoute).join('');
};

const TAGS = Object.keys(render).sort((a, b) => b.length - a.length).join('|');

function expand(html) {
  let out = html;
  // Self-closing first, then the innermost of the paired ones, until none is left.
  const single = new RegExp(`<(${TAGS})\\b([^>]*?)\\s*/>`, 'g');
  const paired = new RegExp(`<(${TAGS})\\b([^>]*)>((?:(?!<(?:${TAGS})\\b)[\\s\\S])*?)</\\1>`);
  out = out.replace(single, (_, tag, a) => render[tag](attrs(a), ''));
  for (let guard = 0; guard < 5000; guard++) {
    const m = paired.exec(out);
    if (!m) break;
    out = out.slice(0, m.index) + render[m[1]](attrs(m[2]), m[3]) + out.slice(m.index + m[0].length);
    out = out.replace(single, (_, tag, a) => render[tag](attrs(a), ''));
  }
  const left = new RegExp(`<\\/?(${TAGS})\\b`).exec(out);
  if (left) throw new Error(`An unclosed <${left[1]}> near: ${out.slice(Math.max(0, left.index - 80), left.index + 80)}`);
  return out;
}

// --- the pages ----------------------------------------------------------------------------------------------------------

const hrefOf = (p) => (p.slug === 'index' ? '/docs/' : `/docs/${p.slug}/`);
// A page's words for the search: its scripts first (the alpha guide has one), then its icons and tags.
const strip = (h) => h.replace(/<script\b[\s\S]*?<\/script>/g, ' ').replace(/<svg[\s\S]*?<\/svg>/g, ' ').replace(/<[^>]+>/g, ' ').replace(/&[a-z#0-9]+;/g, ' ').replace(/\s+/g, ' ').trim();

function shell(p, body, outline, i) {
  const book = p.book;
  const prev = book.pages[i - 1];
  const next = book.pages[i + 1];
  const nav = book.sections
    .map((s) => `<div class="nav-group"><div class="nav-title">${esc(s.title)}</div>${s.pages.map((q) => `<a href="${hrefOf(q)}"${q.slug === p.slug ? ' aria-current="page"' : ''}>${icon(q.icon)}<span>${esc(q.title)}</span>${q.soon ? ' <span class="badge soon">Soon</span>' : ''}</a>`).join('')}</div>`)
    .join('') + `<a class="nav-other" href="${book.other.href}">${icon(book.other.href === '/docs/' ? 'arrow-left' : 'braces')}<span>${esc(book.other.label)}</span></a>`;
  const toc = outline.length > 1 ? `<nav class="toc" aria-label="On this page"><div class="nav-title">On this page</div>${outline.map((h) => `<a href="#${h.id}">${esc(h.text)}</a>`).join('')}</nav>` : '';
  const title = p.slug === 'index' ? 'Uplink docs' : `${p.title} · Uplink ${book.name.toLowerCase()}`;
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>${esc(title)}</title>
<meta name="description" content="${esc(p.summary ?? '')}">
<meta name="theme-color" content="#040406">
<link rel="icon" href="/icon.png">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Saira:ital,wght@0,500;0,600;0,700;1,700;1,800;1,900&amp;display=swap">
<link rel="stylesheet" href="/docs/glacier-tokens.css">
<link rel="stylesheet" href="/docs/docs.css">
<script>try{var t=localStorage.getItem('docs-theme');if(t)document.documentElement.dataset.theme=t}catch(e){}</script>
</head>
<body data-search="/docs/${book.search}">
<a class="skip" href="#main">Skip to the page</a>
<header class="top">
  <button class="menu-btn" type="button" aria-label="Open the list of pages" aria-expanded="false" aria-controls="sidebar">${icon('menu')}</button>
  <a class="brand" href="/"><img src="/art/uplink-logo.webp" alt="Uplink" width="1200" height="918"></a>
  <a class="brand-docs" href="${book.home}">${esc(book.name)}</a>
  <div class="search">
    ${icon('search')}
    <input id="search" type="search" placeholder="Search the ${book.name.toLowerCase()}" aria-label="Search the ${book.name.toLowerCase()}" autocomplete="off">
    <div class="results" id="results" role="listbox" hidden></div>
  </div>
  <button class="theme-btn" type="button" aria-label="Switch between light and dark">${icon('sun-moon')}</button>
  <a class="get" href="/#get"><span>Get Uplink</span></a>
</header>
<div class="frame">
  <aside class="sidebar" id="sidebar">${nav}</aside>
  <main id="main" class="page">
    <div class="crumb"><span class="needle" aria-hidden="true"></span>${esc(p.section)}</div>
    <h1>${esc(p.title)}${p.soon ? ' <span class="badge soon">Coming soon</span>' : ''}</h1>
    ${p.summary ? `<p class="lede">${esc(p.summary)}</p>` : ''}
    ${body}
    <nav class="prevnext">${prev ? `<a class="prev" href="${hrefOf(prev)}"><small>Previous</small>${esc(prev.title)}</a>` : '<span></span>'}${next ? `<a class="next" href="${hrefOf(next)}"><small>Next</small>${esc(next.title)}</a>` : ''}</nav>
    <footer class="foot">Something wrong or missing here? Tell us in the Alpha testers circle, or at <a href="https://github.com/InfamousVague/ghost-messaging/issues">the app's GitHub</a>.</footer>
  </main>
  ${toc}
</div>
<script src="/docs/docs.js" defer></script>
</body>
</html>
`;
}

const written = new Map();
for (const b of books) b.index = [];
pages.forEach((p) => {
  const i = p.book.pages.indexOf(p);
  const file = join(SRC, 'pages', `${p.slug}.html`);
  if (!existsSync(file)) throw new Error(`No page docs-src/pages/${p.slug}.html`);
  const body = expand(readFileSync(file, 'utf8'));
  // Icons a page names itself (<use href="/docs/icons.svg#…">) go in the sprite as the mock tags' do.
  for (const m of body.matchAll(/icons\.svg#([a-z0-9-]+)/g)) icon(m[1]);
  const outline = [...body.matchAll(/<h2 id="([^"]+)"[^>]*>([\s\S]*?)<\/h2>/g)].map((m) => ({ id: m[1], text: strip(m[2]) }));
  written.set(p.slug === 'index' ? 'index.html' : `${p.slug}/index.html`, shell(p, body, outline, i));
  // The first 12,000 characters: the plugin reference pages (the file, phrases) are long, and their later parts are what
  // a developer searches for.
  p.book.index.push({ t: p.title, s: p.section, u: hrefOf(p), d: p.summary ?? '', x: strip(body).slice(0, 12000), h: outline.map((h) => [h.id, h.text]) });
});
for (const name of ['menu', 'search', 'sun-moon', 'chevron-right', 'arrow-left', 'braces']) icon(name);
written.set('icons.svg', sprite());
for (const b of books) written.set(b.search, JSON.stringify(b.index));
written.set('docs.css', readFileSync(join(SRC, 'docs.css'), 'utf8'));
written.set('docs.js', readFileSync(join(SRC, 'docs.js'), 'utf8'));
written.set('glacier-tokens.css', `/* Copied from packages/glacier/assets/css/tokens.css by tool/build-docs.mjs: the app's own design tokens. */\n${readFileSync(join(ROOT, 'packages/glacier/assets/css/tokens.css'), 'utf8')}`);

// --- the Postman collection --------------------------------------------------------------------------------------------
// Both APIs as one collection (v2.1), made from the lists the reference above is drawn from. Its variables are what a
// person fills in: where the app and the relay are, the app's token, and a signed route's headers (Postman can't make
// an install's signature, so those are filled from the caller's own code; docs-src/pages/dev-relay-api.html says how).

// The headers each kind of relay route needs beyond its own (relay-routes.mjs's `auth`).
const SIGNED = [
  { key: 'x-ghost-key', value: '{{ghostKey}}', description: 'The install\'s public key: 33 bytes, compressed, base64.' },
  { key: 'x-ghost-time', value: '{{ghostTime}}', description: 'Now, in milliseconds since 1970.' },
  { key: 'x-ghost-sig', value: '{{ghostSig}}', description: 'The signature over the request: 64 bytes (r then s), base64.' },
];
const BODY_SAID = [
  { key: 'x-ghost-body-sha256', value: '{{ghostBodySha256}}', description: 'The body\'s SHA-256 in hex, said before it is read.' },
  { key: 'x-ghost-body-length', value: '{{ghostBodyLength}}', description: 'The body\'s length in bytes.' },
];
const FILES_TOKEN = { key: 'Authorization', value: 'Ghost {{filesToken}}', description: 'The Files space\'s token.' };
const authHeaders = (r) =>
  ({
    none: [],
    'files-token': [FILES_TOKEN],
    'files-signed': [FILES_TOKEN, ...SIGNED],
    'market-signed': [...SIGNED, ...(r.body && r.body.type !== 'none' ? BODY_SAID : [])],
    'feedback-signed': SIGNED,
  })[r.auth ?? 'none'] ?? (() => { throw new Error(`relay-routes.mjs: ${r.id} has an auth "${r.auth}" the collection doesn't know`); })();

function postmanCollection() {
  const jsonBody = (example) => ({ mode: 'raw', raw: JSON.stringify(example ?? {}, null, 2), options: { raw: { language: 'json' } } });
  const appItem = (m) => ({
    name: m.name,
    request: {
      method: 'POST',
      header: [{ key: 'Content-Type', value: 'application/json' }],
      body: jsonBody(m.example ?? Object.fromEntries(m.params.filter((p) => p.required).map((p) => [p.name, p.example ?? null]))),
      url: { raw: `{{app}}/api/${m.name}`, host: ['{{app}}'], path: ['api', m.name] },
      description: [m.summary, m.danger ? '**Changes or removes something.**' : '', m.params.length ? `Parameters:\n${m.params.map((p) => `- \`${p.name}\` (${p.type}${p.required ? ', needed' : ''}): ${p.doc}`).join('\n')}` : 'No parameters.', `Answers: \`${m.returns}\``].filter(Boolean).join('\n\n'),
    },
  });
  const relayItem = (r) => {
    const of = (where) => (r.params ?? []).filter((p) => p.in === where);
    const path = r.path.split('/').filter(Boolean).map((seg) => seg.replace(/^\{(.+)\}$/, ':$1'));
    const query = of('query').map((p) => ({ key: p.name, value: '', description: p.doc, disabled: !p.required }));
    const body = of('body');
    return {
      name: `${r.method} ${r.path}`,
      request: {
        method: r.method,
        header: [...authHeaders(r), ...of('header').map((p) => ({ key: p.name, value: '', description: p.doc, disabled: !p.required })), ...(r.body?.type === 'json' ? [{ key: 'Content-Type', value: 'application/json' }] : [])],
        ...(r.body?.type === 'json' ? { body: jsonBody(r.body.example ?? Object.fromEntries(body.map((p) => [p.name, null]))) } : {}),
        ...(r.body?.type === 'binary' ? { body: { mode: 'file', file: {} } } : {}),
        url: {
          raw: `{{relay}}/${path.join('/')}${query.length ? `?${query.map((q) => `${q.key}=`).join('&')}` : ''}`,
          host: ['{{relay}}'],
          path,
          ...(query.length ? { query } : {}),
          ...(of('path').length ? { variable: of('path').map((p) => ({ key: p.name, value: '', description: p.doc })) } : {}),
        },
        description: [r.summary, `Who: ${r.who}`, body.length ? `Body:\n${body.map((p) => `- \`${p.name}\`${p.required ? ' (needed)' : ''}: ${p.doc}`).join('\n')}` : '', r.answers ? `Answers: \`${r.answers}\`` : '', r.errors?.length ? `Refusals:\n${r.errors.map((e) => `- \`${e}\``).join('\n')}` : ''].filter(Boolean).join('\n\n'),
      },
    };
  };
  const appGroups = [...new Set(appApi.methods.map((m) => m.group))];
  return {
    info: {
      name: 'Uplink',
      description: 'The app\'s API and the relay server\'s HTTP routes. Made by tool/build-docs.mjs from the app\'s own method registry and docs-src/api/relay-routes.mjs; the reference is at https://gogho.st/docs/developer/api/. The hub and pairing channels are WebSockets and are documented at https://gogho.st/docs/developer/hub/.',
      schema: 'https://schema.getpostman.com/json/collection/v2.1.0/collection.json',
    },
    variable: [
      { key: 'app', value: 'http://127.0.0.1:8765', description: 'Where the app serves its API (Settings › API).' },
      { key: 'token', value: '', description: 'The app\'s token (Settings › API › Copy the token).' },
      { key: 'relay', value: 'https://gogho.st', description: 'The relay server.' },
      { key: 'filesToken', value: '', description: 'A Files space\'s token.' },
      { key: 'ghostKey', value: '', description: 'A signed route\'s x-ghost-key.' },
      { key: 'ghostTime', value: '', description: 'A signed route\'s x-ghost-time.' },
      { key: 'ghostSig', value: '', description: 'A signed route\'s x-ghost-sig.' },
      { key: 'ghostBodySha256', value: '', description: 'A signed Marketplace body\'s SHA-256, in hex.' },
      { key: 'ghostBodyLength', value: '', description: 'A signed Marketplace body\'s length in bytes.' },
    ],
    item: [
      {
        name: 'App API',
        description: `Version ${appApi.version}. POST {{app}}/api/<method> with the parameters as a JSON object and the token. https://gogho.st/docs/developer/app-api/`,
        auth: { type: 'bearer', bearer: [{ key: 'token', value: '{{token}}', type: 'string' }] },
        item: [
          { name: 'Describe every method', request: { method: 'GET', header: [], url: { raw: '{{app}}/api', host: ['{{app}}'], path: ['api'] }, description: 'Everything the API says of itself, as JSON.' } },
          ...appGroups.map((g) => ({ name: g, item: appApi.methods.filter((m) => m.group === g).map(appItem) })),
        ],
      },
      {
        name: 'Relay server API',
        description: 'Plain HTTP on the relay server. https://gogho.st/docs/developer/relay-api/',
        auth: { type: 'noauth' },
        item: relayApi.map((g) => ({ name: g.title, description: g.summary ?? '', item: g.routes.map(relayItem) })),
      },
    ],
  };
}
written.set('api/ghost-messaging.postman_collection.json', `${JSON.stringify(postmanCollection(), null, 2)}\n`);

// The example plugins, byte for byte (Buffers, never re-encoded), so https://gogho.st/docs/examples/bills.ghostplugin is
// a link Settings › Developer › Plugins in development can load on every platform once the site is deployed
// (docs-src/pages/plugin-quick-start.html).
const EXAMPLES = join(ROOT, 'examples/plugins');
if (existsSync(EXAMPLES)) {
  for (const f of readdirSync(EXAMPLES).filter((f) => f.endsWith('.ghostplugin')).sort()) written.set(`examples/${f}`, readFileSync(join(EXAMPLES, f)));
}

if (check) {
  const same = (name, text) => {
    const file = join(OUT, name);
    if (!existsSync(file)) return false;
    return Buffer.isBuffer(text) ? readFileSync(file).equals(text) : readFileSync(file, 'utf8') === text;
  };
  const stale = [...written].filter(([name, text]) => !same(name, text)).map(([n]) => n);
  // site/docs is written whole each time, so a file in it that docs-src no longer makes (an example taken away) is stale too.
  const walk = (dir, at = '') => readdirSync(dir, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(join(dir, e.name), `${at}${e.name}/`) : [`${at}${e.name}`]));
  const extra = existsSync(OUT) ? walk(OUT).filter((name) => !written.has(name)) : [];
  if (stale.length || extra.length) {
    const named = [...stale, ...extra.map((n) => `${n} (not made any more)`)];
    console.error(`site/docs is not what docs-src makes: ${named.slice(0, 8).join(', ')}${named.length > 8 ? '…' : ''}. Run node tool/build-docs.mjs`);
    process.exit(1);
  }
  console.log(`ok site/docs matches docs-src (${pages.length} pages)`);
  process.exit(0);
}
rmSync(OUT, { recursive: true, force: true });
for (const [name, text] of written) {
  const path = join(OUT, name);
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, text);
}
console.log(`ok ${pages.length} pages and ${used.size} icons into site/docs`);
