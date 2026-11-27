/**
 * app.gogho.st: the app in a browser at an address of its own, apart from gogho.st's pages and the relay's own
 * answers there (/link, /files, /market), so nothing slipped into one of those can read what the app keeps in the
 * browser (docs/OPEN_NETWORK.md, part 6). tool/build-web.mjs --app builds it, naming gogho.st's hub; tool/deploy-site.mjs
 * --app ships it, with the block that serves it.
 */
import { readFileSync } from 'node:fs';

export const APP_HOST = 'app.gogho.st';

/** The hub the app.gogho.st build speaks to (lib/web/app.dart: hubFor, GHOST_WEB_HUB). */
export const APP_HUB = 'wss://gogho.st/hub';

/** Where the box keeps its files, swapped in whole as the site's are. */
export const APP_DIR = '/opt/ghost-sms-app';

/** A hub a build may name: wss to any host, or ws to this machine (for trying a build against a relay here). */
export const goodHub = (hub) => /^wss:\/\/[a-z0-9.-]+(:\d{1,5})?\/[A-Za-z0-9._~/-]*$/.test(hub) || /^ws:\/\/(127\.0\.0\.1|localhost)(:\d{1,5})?\/[A-Za-z0-9._~/-]*$/.test(hub);

const META = /<meta http-equiv="Content-Security-Policy" content="([^"]+)">/;

/** The policy a page's `<meta>` gives, from [html]; null where it gives none. */
export const policyOf = (html) => META.exec(html)?.[1] ?? null;

/**
 * What the page sends to beside [hub], over plain HTTP from the page itself (lib/web/http.dart), where the hub is at
 * another address than the page: feedback to the hub's server (lib/feedback/feedback_api.dart feedbackUrlFor), a
 * report to Uplink's review there where the hub is Uplink's own (lib/market/market_api.dart
 * marketIsOwn, marketUrlFor; lib/ui/report_sheet.dart reportsGoFromHere: a page made for another relay sends none),
 * and a Files space's files, from a build with them (lib/files/files_http_web.dart; FilesApi.baseFor: the hub's
 * server, `/files/`). A build without Files spaces never asks there; the one policy serves both, so the site's block
 * needn't change with the build. The relay must also let the page's address read the answers (relay/lib/relay.dart,
 * GHOST_APP_ORIGIN).
 */
export function sentBeside(hub) {
  const u = new URL(hub);
  const at = `${u.protocol === 'wss:' ? 'https:' : 'http:'}//${u.host}${u.pathname.replace(/\/hub$/, '').replace(/\/$/, '')}`;
  const own = u.hostname === 'gogho.st' || u.hostname === 'ghost-sms.com';
  return [...(own ? [`${at}/market/abuse`] : []), `${at}/feedback`, `${at}/files/`];
}

/** connect-src for a build that names [hub]: the page's own address, the hub, and what it sends beside it. */
export const connectFor = (hub) => `connect-src 'self' ${[hub, ...sentBeside(hub)].join(' ')}`;

/** [policy] with connect-src the page's own address, [hub] and what it sends beside it ([connectFor]): what a build
 * that names its hub is held to. */
export function withHub(policy, hub) {
  const parts = policy.split(';').map((p) => p.trim());
  const at = parts.findIndex((p) => p.split(' ')[0] === 'connect-src');
  if (at < 0 || parts[at] !== "connect-src 'self'") throw new Error(`the page's policy has no plain connect-src 'self' to name the hub in (${policy}).`);
  parts[at] = connectFor(hub);
  return parts.join('; ');
}

/** [html] with its policy's connect-src naming [hub] ([withHub]). */
export function pageWithHub(html, hub) {
  const policy = policyOf(html);
  if (policy == null) throw new Error('the page has no Content-Security-Policy.');
  return html.replace(META, `<meta http-equiv="Content-Security-Policy" content="${withHub(policy, hub)}">`);
}

/** The policy of the app.gogho.st build, as the page in web/ (under [root]) says it with gogho.st's hub. */
export function appPolicy(root) {
  const policy = policyOf(readFileSync(`${root}/web/index.html`, 'utf8'));
  if (policy == null) throw new Error('web/index.html has no Content-Security-Policy.');
  return withHub(policy, APP_HUB);
}
