#!/usr/bin/env node
/**
 * Ships gogho.st (before 2026-11-15, ghost-sms.com), Uplink's site (site/), to the box in one ssh session, as Ghost Keyboard's
 * tool/deploy-site.mjs ships ghostkbd.com (Matt, 2026-11-13: "serve it over ghost-sms.com I'll point the domain to
 * the same server ghost kbd uses").
 *
 *   node tool/deploy-site.mjs            the site's files into /opt/ghost-sms-site
 *   node tool/deploy-site.mjs --caddy    that, and the site's block written to /etc/caddy/Caddyfile: added, or put in
 *                                        place of the one there. Needed once, and again when the block below changes.
 *   node tool/deploy-site.mjs --app build/web-app
 *                                        the site, and the app in a browser (tool/build-web.mjs --app) into
 *                                        /opt/ghost-sms-app, swapped in whole as the site is, for app.gogho.st
 *   node tool/deploy-site.mjs --print    the script the box would run, and nothing sent (with the others: what they do)
 *
 * THE APP IN A BROWSER is at an address of its own, app.gogho.st (APP_BLOCK below, tool/lib/web_site.mjs): never under
 * gogho.st, whose pages have scripts written into them and whose /join takes an address to dial, nor beside the relay's
 * /link, /files and /market, so nothing slipped into any of those can read what the app keeps in the browser. Its block
 * sends every header in tool/web/headers.json (test/web_build_test.dart holds it to that list, and the page's own
 * policy), and answers /clear-site-data with `Clear-Site-Data: "storage"`, which the page asks for as it signs out or
 * is removed, to the page itself alone (`Sec-Fetch-Site: same-origin`; from anywhere else a link to it would sign the
 * person out). Its DNS record is the owner's to add, and --caddy is to be run after it exists: the box writes the block
 * only once app.gogho.st points at it (Caddy's retries for a certificate it can't get yet back off for hours), and
 * then asks app.gogho.st itself, as a visitor would, for the page, a 404 and the worker (and /clear-site-data, from the
 * page and from another site), and puts the Caddyfile back if any header on the list is missing. Run while its DNS
 * can't be checked, --caddy leaves the app's block as it is. No Caddy runs on the computer this is shipped from: the box is where it is
 * checked.
 *
 * The download and its version are the release's own files (/ghost-messaging.apk and /apk.json, served from
 * /opt/ghost-sms-release by the block), so a release (tool/release.mjs) updates this site's download with nothing to
 * do here. INSTALLED COPIES UPDATE FROM THOSE TWO ADDRESSES (Updater.BASE): a block under which they stop answering
 * is put back, never kept.
 *
 * It uses Ghost.md's box account and its own deploy code, as tool/release.mjs does (this app lives in Ghost.md's
 * repository, so the checkout is the folder above; --glyph <path> or GLYPH_ROOT say otherwise). THE CADDYFILE IS
 * SHARED (attack.fm, ghostmarkdown.com, ghostkbd.com and more), so --caddy is glyph's scripts/deploy-landing.mjs
 * procedure, line for line: it touches only this site's own blocks (gogho.st's, ghost-sms.com's, app.gogho.st's, and those of the site's other names, satellite.im and deepspaceshipping.co, which serve the site themselves); a timestamped backup; every other site asked
 * for its page before; the block written; `caddy validate`; a reload; every other site asked again; a failed
 * validate, or any site answering differently, puts the backup back. Caddy gets the certificate by itself, once the
 * domain's DNS points at the box. The box counts logins: this spends one.
 */
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, symlinkSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { APP_DIR, APP_HOST, APP_HUB, appPolicy, policyOf } from './lib/web_site.mjs';

/** The headers both of the app's addresses send (test/web_build_test.dart and relay/test/web_app_test.dart hold to it). */
const HEADERS = JSON.parse(readFileSync(join(dirname(fileURLToPath(import.meta.url)), 'web', 'headers.json'), 'utf8'));

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const SITE_DIR = join(ROOT, 'site');
const SITE = '/opt/ghost-sms-site';
const RELEASE = '/opt/ghost-sms-release';
const APK = 'ghost-messaging.apk';
// The Mac app's (tool/release-mac.mjs): what an installed copy reads, and the zip it updates itself from.
const MAC_ZIP = 'ghost-messaging-mac.zip';
// The Mac download as the site offers it, a notarised disk image (tool/release-mac.mjs; Matt, 2026-11-19: "deploy it from a dmg").
const MAC_DMG = 'ghost-messaging-mac.dmg';
const DOMAIN = 'gogho.st';
// The site's first address (Matt, 2026-11-15: "I got the domain gogho.st hooked up the box, please update all the links
// in app and everything to point through that domain instead of the ghost-sms one also point that domain to the
// website"). It still answers what copies installed before the move ask of it - their updates and the relay - and
// the relay's sign-in pages (/link/*, whose addresses Discord, X and Telegram were given); anything else there goes
// to the same address on gogho.st. /discord/* answers on both names (the Discord presence bot, tool/deploy-discord.mjs).
const OLD = 'ghost-sms.com';
// Other names the site answers under itself, the same pages with nothing sent on (Matt, 2026-11-27: "update the box so
// satellite.im and deepspaceshipping.co don't redirect simply serve the uplink page"). satellite.im was sent on to
// gogho.st until then, as he first asked (2026-11-20: "link satellite.im to the list of domains and point it to the
// gogho.st page"). A name's DNS has to point at the box (as gogho.st's does) before Caddy can get it a certificate, so
// each gets its block only once it does (alsoBlock, and ALSO_IN on the box).
const ALSO = ['satellite.im', 'deepspaceshipping.co'];
// The release's own files, as every block that serves them names them.
const RELEASED = `/${APK} /apk.json /${MAC_ZIP} /${MAC_DMG} /mac.json /ghost-messaging-setup.exe /windows.json /ghost-messaging-linux.deb /ghost-messaging-linux-x64.tar.gz /linux.json`;
const args = process.argv.slice(2);
const withCaddy = args.includes('--caddy');
const printOnly = args.includes('--print');
const fail = (message) => { console.error(`x ${message}`); process.exit(1); };
const appAt = args.indexOf('--app');
if (appAt >= 0 && (appAt + 1 >= args.length || args[appAt + 1].startsWith('--'))) fail('--app takes the built folder: node tool/build-web.mjs --app, then --app build/web-app.');
const APP_BUILD = appAt >= 0 ? resolve(args[appAt + 1]) : null;

// app.gogho.st's policy: the page's own (web/index.html) with gogho.st's hub, and frame-ancestors, which only a header
// can say. Written out in APP_BLOCK, where a test reads it (test/web_build_test.dart), and held here to the page.
const APP_CSP = "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; worker-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self'; media-src 'self' data: blob:; connect-src 'self' wss://gogho.st/hub https://gogho.st/market/abuse https://gogho.st/feedback https://gogho.st/files/; manifest-src 'self'; base-uri 'self'; form-action 'none'; frame-src 'none'; object-src 'none'; frame-ancestors 'none'";
// Checked on every run: a page whose policy changed and a block that still sends the old one would leave the app on
// app.gogho.st held to a policy it no longer has.
const wantCsp = `${appPolicy(ROOT)}; frame-ancestors 'none'`;
if (wantCsp !== APP_CSP) {
  fail(`web/index.html's policy has changed, and app.gogho.st's block in tool/deploy-site.mjs still sends the old one, so nothing was shipped (not the site either). Put this in APP_CSP, near the top of tool/deploy-site.mjs:\n  ${wantCsp}\nthen run flutter test test/web_build_test.dart, which holds the block to the page, and this again.`);
}

// The built app, checked before anything is sent: the page at its top, made for app.gogho.st (served from /, speaking
// to gogho.st's hub, its policy the block's), and its files all plain ones.
if (APP_BUILD) {
  if (!existsSync(join(APP_BUILD, 'index.html'))) fail(`No index.html in ${APP_BUILD}: build it with node tool/build-web.mjs --app.`);
  const page = readFileSync(join(APP_BUILD, 'index.html'), 'utf8');
  // Served from / (app.gogho.st, once its DNS record exists) or from /app/ (gogho.st/app, Matt's choice of 2026-11-23
  // while it doesn't): the one folder is both, so it is built for the one in use (--base /app/ for gogho.st/app).
  if (!page.includes('<base href="/">') && !page.includes('<base href="/app/">')) fail(`${APP_BUILD} was built to be served from another folder than / or /app/: build it with node tool/build-web.mjs --app, or --base /app/ --hub wss://gogho.st/hub for gogho.st/app.`);
  if (`${policyOf(page)}; frame-ancestors 'none'` !== APP_CSP) fail(`${APP_BUILD}'s page has another policy than app.gogho.st's block sends (built for another hub than ${APP_HUB}, or before the page's policy last changed?): build it again with node tool/build-web.mjs --app.`);
  if (!readdirSync(APP_BUILD).some((n) => /^main\.dart\.[0-9a-f]{8,}\.js$/.test(n))) fail(`${APP_BUILD} has no main.dart.<hash>.js: it is not what tool/build-web.mjs builds.`);
  // The fonts for letters outside the app's own (tool/web/fallback-fonts.mjs): shipped without them, Chinese, Japanese,
  // Korean, Arabic, Devanagari, mathematics and the rest are drawn as boxes. Said, not refused.
  if (!existsSync(join(APP_BUILD, 'fallback-fonts'))) {
    console.log(`! ${APP_BUILD} has no fallback fonts: on app.gogho.st, letters outside the app's own fonts (Chinese, Japanese, Korean, Arabic, Devanagari, mathematics, some symbols) will be drawn as boxes. node tool/web/fallback-fonts.mjs --fetch (it asks fonts.gstatic.com for them, once) and its licence in build/fallback-fonts/OFL.txt, then node tool/build-web.mjs --app again.`);
  }
}

if (!existsSync(join(SITE_DIR, 'index.html'))) fail('No site/index.html to ship.');
// The App Links file goes with the rest (the tarball takes dot folders too): without it, installed copies stop
// opening gogho.st/join links straight away the next time Android checks.
if (!existsSync(join(SITE_DIR, '.well-known', 'assetlinks.json'))) fail('No site/.well-known/assetlinks.json to ship.');
const at = args.indexOf('--glyph');
const glyph = [at >= 0 ? args[at + 1] : null, process.env.GLYPH_ROOT, join(ROOT, '..'), join(ROOT, '..', 'glyph'), join(homedir(), 'Development/Apps/glyph')]
  .filter(Boolean)
  .find((dir) => existsSync(join(dir, 'tauri/scripts/lib/box.mjs')));
if (!glyph && !printOnly) fail('No Ghost.md checkout found for its box code (--glyph <path> or GLYPH_ROOT).');

// www answers with a redirect to the bare name. The release's two files come from the release's own folder; every
// other address is the site's. Nothing is cached hard: the site is small and changes with the app.
const BLOCK = `
${DOMAIN} {
	encode zstd gzip
	# The release's own files (tool/release.mjs, tool/release-mac.mjs), so a release updates this site's download
	# and version. Installed copies update from these addresses (the phone's Updater.BASE, the Mac's macFeed): they
	# must never stop answering.
	@release path ${RELEASED}
	handle @release {
		root * ${RELEASE}
		header Cache-Control "no-cache"
		file_server
	}
	# The relay (relay/, tool/deploy-relay.mjs): a phone and the computer it is paired with at /relay/<channel>, and
	# the hub two people's apps find each other through at /hub. WebSockets, passed to the service on this box.
	# The port is tool/deploy-relay.mjs's PORT: the two must agree. /link/* is the same service's pages for signing
	# in with a network to link an account (relay/lib/handles.dart, docs/me.md): what Discord, X and Telegram send
	# a person back to.
	@relay path /hub /relay/* /link/* /word/*
	handle @relay {
		reverse_proxy 127.0.0.1:18787
	}
	# Someone's add-me link (gogho.st/add/maya; GMFB-34, site/add/index.html): one page for every username.
	@add path_regexp add ^/add/@?[A-Za-z0-9._]+/?$
	handle @add {
		root * ${SITE}
		header Cache-Control "no-cache"
		rewrite * /add/index.html
		file_server
	}
	# A circle's invite word (gogho.st/c/bookclub; relay/lib/invite_words.dart, site/c/index.html): one page for every
	# word, which asks the relay's /word/<hash> above for the circle's sealed link and opens it.
	@word path_regexp word ^/c/[A-Za-z0-9-]+/?$
	handle @word {
		root * ${SITE}
		header Cache-Control "no-cache"
		rewrite * /c/index.html
		file_server
	}
	# Files spaces' sealed files (relay/lib/files.dart): plain HTTP to the same service. A file goes up in pieces of at
	# most 8 MB (the relay's maxBody), so no request needs more than this; a download streams back with Range. Not
	# buffered here either way: flush_interval -1 passes each piece on as it comes.
	# Timeouts (Matt, 2026-11-17: "Finish the missing pieces that went unfinished"): the relay must be reached at once,
	# and must answer within two minutes of a request's last byte arriving (it answers a piece once it has it, a log
	# page or a delete at once). Neither runs while a body is still coming, so a slow phone's 8 MB piece is not cut
	# off. A body that stops coming is the relay's to end (files.dart's bodyPause, 30 s without a byte): Caddy's own
	# read_body timeout is for every site on this box, not one route, so it is not set here.
	# The Marketplace (relay/lib/market.dart) is the same service's too: a body that stops coming is the market's to end
	# (60 s for the whole of one, 30 s without a byte), for the same reason. 10MiB, not 10MB: Caddy reads MB as 1,000,000 bytes, and
	# the relay holds Files' pieces and the market's bodies to 10 << 20 = 10,485,760 bytes, which a body between the two
	# passed there and was cut here (review, 2026-11-20).
	@files path /files /files/* /feedback /bounty /souls/* /market /market/*
	handle @files {
		request_body {
			max_size 10MiB
		}
		reverse_proxy 127.0.0.1:18787 {
			flush_interval -1
			transport http {
				dial_timeout 5s
				response_header_timeout 2m
			}
		}
	}
	# The Discord presence bot (discord/, tool/deploy-discord.mjs): a linked Discord server's voice channels and who
	# is in them, for the app's spaces. Passed on with the /discord prefix kept; the port is that script's PORT.
	@discord path /discord /discord/*
	handle @discord {
		reverse_proxy 127.0.0.1:18788
	}
	# The app in a browser under /app/ (Matt, 2026-11-23: "Deploy the website version as a open in browser option on
	# the website", choosing gogho.st/app over waiting for app.gogho.st's DNS record): the same folder, headers and
	# answers as APP_BLOCK below, the prefix taken off.
	redir /app /app/ permanent
	@appclear {
		path /app/clear-site-data
		header Sec-Fetch-Site same-origin
	}
	handle @appclear {
		header Clear-Site-Data "\\"storage\\""
		header Cache-Control "no-store"
		respond 204
	}
	handle_path /app/* {
		root * ${APP_DIR}
		header {
			Content-Security-Policy "${APP_CSP}"
			X-Frame-Options "DENY"
			X-Content-Type-Options "nosniff"
			Referrer-Policy "no-referrer"
			Cross-Origin-Opener-Policy "same-origin"
			Cross-Origin-Resource-Policy "same-origin"
			Permissions-Policy "camera=(self), microphone=(self), geolocation=(), display-capture=()"
		}
		@apphashed path_regexp apphashed \\.[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]+\\.[A-Za-z0-9]+$
		handle @apphashed {
			header Cache-Control "public, max-age=31536000, immutable"
			file_server {
				precompressed br gzip
				hide .*
			}
		}
		handle {
			header Cache-Control "no-cache"
			file_server {
				precompressed br gzip
				hide .*
			}
		}
	}
	# Android App Links (site/.well-known/assetlinks.json): what Android reads to open gogho.st/join links in the app
	# straight away (Matt, 2026-11-17: invites texted to contacts). It must answer 200 as application/json, with no
	# redirect, so it is served here by itself.
	@assetlinks path /.well-known/assetlinks.json
	handle @assetlinks {
		root * ${SITE}
		header Content-Type "application/json"
		header Cache-Control "no-cache"
		file_server
	}
	# The example plugins the docs link (docs-src/examples/*.ghostplugin): a ghost-plugin/1 file is JSON, which Caddy
	# can't tell from the extension, so without this a download, or a fetch that doesn't take gzip, came with no type.
	@plugins path *.ghostplugin
	handle @plugins {
		root * ${SITE}
		header Content-Type "application/json"
		header Cache-Control "no-cache"
		header X-Content-Type-Options "nosniff"
		header Referrer-Policy "strict-origin-when-cross-origin"
		file_server
	}
	handle {
		root * ${SITE}
		header Cache-Control "no-cache"
		header X-Content-Type-Options "nosniff"
		header Referrer-Policy "strict-origin-when-cross-origin"
		file_server
	}
}
www.${DOMAIN} {
	redir https://${DOMAIN}{uri} permanent
}
${OLD} {
	encode zstd gzip
	@release path ${RELEASED}
	handle @release {
		root * ${RELEASE}
		header Cache-Control "no-cache"
		file_server
	}
	@relay path /hub /relay/* /link/*
	handle @relay {
		reverse_proxy 127.0.0.1:18787
	}
	# Files, feedback and the Marketplace (relay/lib/market.dart), as above; a body that stops coming is the market's to end.
	@files path /files /files/* /feedback /bounty /souls/* /market /market/*
	handle @files {
		request_body {
			max_size 10MiB
		}
		reverse_proxy 127.0.0.1:18787 {
			flush_interval -1
			transport http {
				dial_timeout 5s
				response_header_timeout 2m
			}
		}
	}
	@discord path /discord /discord/*
	handle @discord {
		reverse_proxy 127.0.0.1:18788
	}
	handle {
		redir https://${DOMAIN}{uri} permanent
	}
}
www.${OLD} {
	redir https://${DOMAIN}{uri} permanent
}
`;

// One of the site's other names (ALSO): the site's own pages, its docs and the release's files, under that name and
// with nothing sent on. What can only be gogho.st's goes there: the app in a browser (its page's policy, and the
// account a browser keeps, are gogho.st's), the pages an app's link opens (an invite, an add-me link, a circle's word,
// a pairing code: the apps write those links with gogho.st, and the pages speak to the relay from it), and the relay
// itself. Not the matcher's name the two blocks above share, and nothing passed to the relay from here.
const alsoBlock = (name) => `
${name} {
	encode zstd gzip
	@release path ${RELEASED}
	handle @release {
		root * ${RELEASE}
		header Cache-Control "no-cache"
		file_server
	}
	@gogho path /app /app/* /join /join/* /add /add/* /c /c/* /pair /pair/* /hub /relay/* /link/* /word/* /market /market/* /files /files/* /feedback /bounty /souls/* /discord /discord/*
	handle @gogho {
		redir https://${DOMAIN}{uri}
	}
	handle {
		root * ${SITE}
		header Cache-Control "no-cache"
		header X-Content-Type-Options "nosniff"
		header Referrer-Policy "strict-origin-when-cross-origin"
		file_server
	}
}
`;
// Its www, sent to the name itself, where that has a DNS record of its own pointing here.
const alsoWwwBlock = (name) => `
www.${name} {
	redir https://${name}{uri} permanent
}
`;

// The app in a browser at an address of its own (tool/lib/web_site.mjs): its files and nothing else, every answer
// with the headers in tool/web/headers.json (test/web_build_test.dart reads this block and holds it to that list and
// to the page's policy). It speaks to gogho.st's hub, which its build names and its policy allows, and to nothing
// else. A file named by its hash (main.dart.<hash>.js) is kept a year; everything else is asked for again each time.
// Each file is sent packed where the build packed it beforehand (.br, .gz beside it), and a name starting with a dot
// (.last_build_id) is never sent.
const APP_BLOCK = `
${APP_HOST} {
	root * ${APP_DIR}
	header {
		Content-Security-Policy "${APP_CSP}"
		X-Frame-Options "DENY"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "no-referrer"
		Cross-Origin-Opener-Policy "same-origin"
		Cross-Origin-Resource-Policy "same-origin"
		Permissions-Policy "camera=(self), microphone=(self), geolocation=(), display-capture=()"
		Strict-Transport-Security "max-age=31536000"
	}
	@clear {
		path /clear-site-data
		header Sec-Fetch-Site same-origin
	}
	handle @clear {
		header Clear-Site-Data "\\"storage\\""
		header Cache-Control "no-store"
		respond 204
	}
	@hashed path_regexp hashed \\.[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]+\\.[A-Za-z0-9]+$
	handle @hashed {
		header Cache-Control "public, max-age=31536000, immutable"
		file_server {
			precompressed br gzip
			hide .*
		}
	}
	handle {
		header Cache-Control "no-cache"
		file_server {
			precompressed br gzip
			hide .*
		}
	}
}
`;

// What app.gogho.st must answer with on the page, a 404 and the worker, as `name: value` lines: every header on
// tool/web/headers.json's list, the policy, HSTS and no-cache. The box checks them as a visitor gets them, once the
// block is live, and puts the Caddyfile back where any is missing (it was written and checked as text alone before:
// no Caddy runs on the computer this is shipped from).
const APP_WANTED = [...Object.entries({ ...HEADERS.every, ...HEADERS.app }).map(([name, value]) => `${name}: ${value}`), `Content-Security-Policy: ${APP_CSP}`];
// And the one answer the page asks for as it signs out or is removed (lib/web/browser_web.dart, the relay's own in
// relay/lib/web_app.dart): APP_BLOCK's @clear. Only to the page itself (`Sec-Fetch-Site: same-origin`): from anywhere
// else it is a file that isn't there, or any link to it would sign the person out (third review, A2).
const CLEAR_PATH = 'clear-site-data';
const CLEAR_WANTED = 'Clear-Site-Data: "storage"';

// Every name's block is this site's (app.gogho.st's too, kept apart from gogho.st's own): each is taken out and
// written again.
const escaped = (name) => name.replaceAll('.', '[.]');
const dom = `(${[DOMAIN, OLD, ...ALSO, APP_HOST].map(escaped).join('|')})`;
// The two that are always written again. app.gogho.st's block and each other name's (ALSO) are taken out only where a
// new one goes in: with a name's DNS not pointing here just now (or a lookup that failed for a moment) the block it
// has, if any, stays as it is.
const domCore = [DOMAIN, OLD].map(escaped).join('|');
// Run on the box. Reads the site as a tarball on stdin; with --app, the site under site/ and the app under app/.
const REMOTE = `set -e
SUDO=; [ "$(id -u)" -eq 0 ] || SUDO=sudo
STAGE="$HOME/.ghost-sms-site-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"; tar xzf - -C "$STAGE"
SRC="$STAGE${APP_BUILD ? '/site' : ''}"
[ -f "$SRC/index.html" ] || { echo "x the site arrived without its index.html"; exit 1; }
[ -f "$SRC/.well-known/assetlinks.json" ] || { echo "x the site arrived without .well-known/assetlinks.json"; exit 1; }
$SUDO mkdir -p ${SITE}.next
$SUDO rm -rf ${SITE}.next/*
$SUDO cp -a "$SRC"/. ${SITE}.next/
$SUDO chmod -R a+rX ${SITE}.next
# Swapped in whole, so a visitor never gets a page of one version with scripts of another.
if [ -d ${SITE} ]; then $SUDO rm -rf ${SITE}.old; $SUDO mv ${SITE} ${SITE}.old; fi
$SUDO mv ${SITE}.next ${SITE}
$SUDO rm -rf ${SITE}.old
echo "ok site in ${SITE}: $(ls ${SITE} | tr '\\n' ' ')"
# The app in a browser, for ${APP_HOST}: swapped in whole as the site is, so a page of one build never loads the
# engine or the code of another.
if [ -d "$STAGE/app" ]; then
  [ -f "$STAGE/app/index.html" ] || { echo "x the app arrived without its index.html"; exit 1; }
  $SUDO rm -rf ${APP_DIR}.next
  $SUDO mkdir -p ${APP_DIR}.next
  $SUDO cp -a "$STAGE/app"/. ${APP_DIR}.next/
  $SUDO chmod -R a+rX ${APP_DIR}.next
  if [ -d ${APP_DIR} ]; then $SUDO rm -rf ${APP_DIR}.old; $SUDO mv ${APP_DIR} ${APP_DIR}.old; fi
  $SUDO mv ${APP_DIR}.next ${APP_DIR}
  $SUDO rm -rf ${APP_DIR}.old
  echo "ok app in ${APP_DIR}: $(find ${APP_DIR} -type f | wc -l | tr -d ' ') files"
fi
rm -rf "$STAGE"
[ "${withCaddy ? 1 : 0}" = 1 ] || exit 0
CF=/etc/caddy/Caddyfile

# Every site on the Caddyfile, asked for its page on the box itself, by name.
probe() {
  for h in $($SUDO grep -E '^[a-z0-9][a-z0-9.:/, -]*[{]' "$CF" | sed 's/{.*//; s/,/ /g'); do
    h=\${h#http://}; h=\${h#https://}; h=\${h%%:*}
    [ -n "$h" ] || continue
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$h:443:127.0.0.1" "https://$h/" || true)
    echo "$h $code"
  done | sort
}
# app.gogho.st's block goes in only once its DNS record points at this box, as gogho.st's does: before that Caddy can't
# get its certificate, and its retries back off for hours, so the app's address would stay without one long after the
# record is made. --caddy is to be run again once the record is there (it says so below).
APP_IP=$(getent ahostsv4 ${APP_HOST} 2>/dev/null | awk 'NR==1 { print $1 }')
SITE_IP=$(getent ahostsv4 ${DOMAIN} 2>/dev/null | awk 'NR==1 { print $1 }')
WITH_APP=0
if [ -n "$APP_IP" ] && [ "$APP_IP" = "$SITE_IP" ]; then WITH_APP=1; else echo "! ${APP_HOST}'s DNS record doesn't point at this box yet (${APP_HOST}: \${APP_IP:-none}, ${DOMAIN}: \${SITE_IP:-none}): its block is left out. Run --caddy again once it does."; fi
# The site's other names (${ALSO.join(', ')}), for the same reason: each gets its block only once its own DNS record
# points at this box, and one that doesn't yet is left as it is. A name's www likewise, apart from the name.
points() { ip=$(getent ahostsv4 "$1" 2>/dev/null | awk 'NR==1 { print $1 }'); [ -n "$ip" ] && [ -n "$SITE_IP" ] && [ "$ip" = "$SITE_IP" ]; }
ALSO_IN=""
for n in ${ALSO.join(' ')}; do
  if points "$n"; then ALSO_IN="$ALSO_IN $n"; else echo "! $n's DNS record doesn't point at this box yet ($n: \${ip:-none}, ${DOMAIN}: \${SITE_IP:-none}): it is left as it is. Point its A record at \${SITE_IP:-the box} and run --caddy again."; fi
done
BACKUP="$CF.bak-$(date +%Y%m%d-%H%M%S)"
$SUDO cp -a "$CF" "$BACKUP"
echo "ok backup $BACKUP"
# What installed copies update from. Where it answered before, it must answer after.
feeds() { for p in /apk.json /${APK}; do curl -s -o /dev/null -w "$p %{http_code}\\n" -I --max-time 10 --resolve "${OLD}:443:127.0.0.1" "https://${OLD}$p" || true; done; }
FEEDS=$(feeds)
BEFORE=$(probe | grep -v -E '^(www[.])?${dom} ' || true)
echo "before:"; echo "$BEFORE" | sed 's/^/  /'
restore() { echo "x $1: putting $BACKUP back"; $SUDO cp -a "$BACKUP" "$CF"; $SUDO systemctl reload caddy || true; exit 1; }
# The domain's own blocks out, if they are there - each from its first line to the next brace at the start of a line -
# and the new ones on the end.
# app.gogho.st's block is taken out only where a new one goes in: with its DNS not checked just now (a lookup that failed
# for a moment) the block it has stays, where once --caddy took a live app's block away (third review).
NAMES='${domCore}'
[ "$WITH_APP" = 0 ] || NAMES="$NAMES|${escaped(APP_HOST)}"
for n in $ALSO_IN; do NAMES="$NAMES|$(printf '%s' "$n" | sed 's/[.]/[.]/g')"; done
START="^(www[.])?($NAMES)[ ,{]"
$SUDO awk -v start="$START" '$0 ~ start { skip = 1; next } skip && /^}/ { skip = 0; next } !skip' "$CF" | $SUDO tee "$CF.next" >/dev/null
printf '%s\\n' '${BLOCK.replace(/'/g, "'\\''")}' | $SUDO tee -a "$CF.next" >/dev/null
[ "$WITH_APP" = 0 ] || printf '%s\\n' '${APP_BLOCK.replace(/'/g, "'\\''")}' | $SUDO tee -a "$CF.next" >/dev/null
${ALSO.map((name) => `case " $ALSO_IN " in *" ${name} "*)
  printf '%s\\n' '${alsoBlock(name).replace(/'/g, "'\\''")}' | $SUDO tee -a "$CF.next" >/dev/null
  if points "www.${name}"; then printf '%s\\n' '${alsoWwwBlock(name).replace(/'/g, "'\\''")}' | $SUDO tee -a "$CF.next" >/dev/null; fi ;;
esac`).join('\n')}
# Copied onto the Caddyfile rather than moved over it, so the file keeps its owner and its mode.
$SUDO cp "$CF.next" "$CF"; $SUDO rm -f "$CF.next"
echo "the new blocks:"; $SUDO awk -v start='^(www[.])?${dom}[ ,{]' '$0 ~ start { on = 1 } on { print "  " $0 } on && /^}/ { on = 0 }' "$CF"
$SUDO caddy validate --config "$CF" --adapter caddyfile >/dev/null 2>&1 || restore "caddy validate refused it"
$SUDO systemctl reload caddy || restore "caddy would not reload"
sleep 4
AFTER=$(probe | grep -v -E '^(www[.])?${dom} ' || true)
echo "after:"; echo "$AFTER" | sed 's/^/  /'
[ "$BEFORE" = "$AFTER" ] || restore "a site answers differently after the reload"
if [ "$FEEDS" = "$(printf '/apk.json 200\\n/${APK} 200')" ]; then
  [ "$(feeds)" = "$FEEDS" ] || restore "https://${OLD}/apk.json or /${APK} no longer answers, and copies installed before gogho.st update from them"
  echo "ok /apk.json and /${APK} answer as before"
fi
# Each other name answers the site's own page under itself: the very page ${DOMAIN} gives, not a redirect to it and
# not another site's. A name new to the box waits for its certificate first (two minutes at most).
page() { curl -s --max-time 10 --resolve "$1:443:127.0.0.1" "https://$1/" | sha256sum | awk '{ print $1 }'; }
for n in $ALSO_IN; do
  ok=0
  for i in $(seq 1 30); do
    if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$n:443:127.0.0.1" "https://$n/" || true)" = 200 ] && [ "$(page "$n")" = "$(page ${DOMAIN})" ]; then ok=1; break; fi
    sleep 4
  done
  [ "$ok" = 1 ] || restore "https://$n does not answer with ${DOMAIN}'s page"
  echo "ok https://$n answers with the site's page itself"
done
# app.gogho.st as a visitor gets it, once Caddy has its certificate (waited for, two minutes at most): every header on
# the list on the page, on a 404 and on the worker, whose policy only the header can give it. Any missing, or no answer
# at all, puts the Caddyfile back.
if [ "$WITH_APP" = 1 ]; then
  WANT="$(mktemp)"
  printf '%s\\n' '${APP_WANTED.join('\n').replace(/'/g, "'\\''")}' > "$WANT"
  appcheck() {
    for p in / /argon2id.js /no-such-file-here.js; do
      h=$(curl -sS -D - -o /dev/null --max-time 10 --resolve "${APP_HOST}:443:127.0.0.1" "https://${APP_HOST}$p" | tr -d '\\r') || { echo "  $p: no answer"; return 1; }
      while IFS= read -r w; do printf '%s\\n' "$h" | grep -Fxiq -- "$w" || { echo "  $p lacks $w"; return 1; }; done < "$WANT"
      case "$p" in /no-such-file-here.js) ;; *) printf '%s\\n' "$h" | grep -Fxiq -- 'Cache-Control: ${HEADERS.cache.plain}' || { echo "  $p lacks Cache-Control: ${HEADERS.cache.plain}"; return 1; } ;; esac
    done
    # What the page asks for as it signs out or is removed: the browser told to clear everything it keeps for the app.
    h=$(curl -sS -D - -o /dev/null --max-time 10 -H 'Sec-Fetch-Site: same-origin' --resolve "${APP_HOST}:443:127.0.0.1" "https://${APP_HOST}/${CLEAR_PATH}" | tr -d '\\r') || { echo "  /${CLEAR_PATH}: no answer"; return 1; }
    printf '%s\\n' "$h" | grep -Fxiq -- '${CLEAR_WANTED}' || { echo "  /${CLEAR_PATH} lacks its Clear-Site-Data header"; return 1; }
    # And only to the page itself: asked from anywhere else (no Sec-Fetch-Site, another site's), it clears nothing.
    for from in '' 'Sec-Fetch-Site: cross-site'; do
      h=$(curl -sS -D - -o /dev/null --max-time 10 \${from:+-H "$from"} --resolve "${APP_HOST}:443:127.0.0.1" "https://${APP_HOST}/${CLEAR_PATH}" | tr -d '\\r') || { echo "  /${CLEAR_PATH}: no answer"; return 1; }
      if printf '%s\\n' "$h" | grep -iq '^clear-site-data:'; then echo "  /${CLEAR_PATH} clears for a request not from the page (\${from:-no Sec-Fetch-Site})"; return 1; fi
    done
  }
  ok=0
  for i in $(seq 1 30); do if appcheck >/dev/null 2>&1; then ok=1; break; fi; sleep 4; done
  if [ "$ok" = 1 ]; then echo "ok https://${APP_HOST} answers with every header on the list (/, a 404, /argon2id.js), and /${CLEAR_PATH} with its Clear-Site-Data header"; else appcheck || true; rm -f "$WANT"; restore "https://${APP_HOST} did not answer with every header on tool/web/headers.json's list, or /${CLEAR_PATH} without its Clear-Site-Data header"; fi
  rm -f "$WANT"
fi
echo "ok ${DOMAIN}'s blocks written and live"
`;

/** Every file under [dir], and their bytes. */
const measure = (dir) => {
  let files = 0, bytes = 0;
  const walk = (d) => {
    for (const e of readdirSync(d, { withFileTypes: true })) {
      if (e.isDirectory()) walk(join(d, e.name));
      else {
        files++;
        bytes += statSync(join(d, e.name)).size;
      }
    }
  };
  walk(dir);
  return { files, bytes };
};

console.log(`> Shipping ${DOMAIN}${withCaddy ? ' and its Caddy blocks' : ''} (one ssh session)`);
if (APP_BUILD) {
  const { files, bytes } = measure(APP_BUILD);
  console.log(`> and the app in a browser for ${APP_HOST}, from ${APP_BUILD} (${files} files, ${(bytes / 1048576).toFixed(1)} MB), into ${APP_DIR}`);
}
if (printOnly) {
  process.stdout.write(REMOTE);
  process.exit(0);
}

const { BOX_ENV_KEYS, boxSshOptions, openBox, tarball } = await import(pathToFileURL(join(glyph, 'tauri/scripts/lib/box.mjs')).href);
const { loadEnv } = await import(pathToFileURL(join(glyph, 'scripts/lib/env.mjs')).href);
/** The site and the app in one tarball, under site/ and app/ (links to the two folders, followed by tar). */
const both = () => {
  const stage = mkdtempSync(join(tmpdir(), 'ghost-site-'));
  try {
    symlinkSync(SITE_DIR, join(stage, 'site'));
    symlinkSync(APP_BUILD, join(stage, 'app'));
    const tar = spawnSync('tar', ['-czhf', '-', '--no-xattrs', '--no-mac-metadata', '-C', stage, 'site', 'app'], { maxBuffer: 1024 * 1024 * 1024 });
    if (tar.status !== 0) fail(`tar failed: ${String(tar.stderr)}`);
    return tar.stdout;
  } finally {
    rmSync(stage, { recursive: true, force: true });
  }
};
const site = APP_BUILD ? both() : tarball(SITE_DIR, 64 * 1024 * 1024);
const env = loadEnv(BOX_ENV_KEYS);
const box = openBox(env, boxSshOptions({ connectTimeout: 20, knownHosts: join(homedir(), '.ssh', 'known_hosts') }));
box.logIn();
const result = box.exec(REMOTE, { input: site, stdio: ['pipe', 'inherit', 'inherit'] });
if (!args.includes('--keep-connection')) box.close();
if (result.status !== 0) fail(result.status === 5 ? 'ssh refused the password: if .env is right, this is the box\'s lockout; wait it out.' : 'The remote step failed (output above).');

// From here, as a visitor would: the page, the version, and the download's headers.
const curl = (a) => spawnSync('curl', ['-s', '--max-time', '15', ...a], { encoding: 'utf8' });
const page = curl(['-o', '/dev/null', '-w', '%{http_code}', `https://${DOMAIN}/`]).stdout;
const info = curl(['-o', '/dev/null', '-w', '%{http_code}', `https://${DOMAIN}/apk.json`]).stdout;
const apk = curl(['-o', '/dev/null', '-w', '%{http_code}', '-r', '0-0', `https://${DOMAIN}/${APK}`]).stdout;
const links = curl(['-o', '/dev/null', '-w', '%{http_code} %{content_type}', `https://${DOMAIN}/.well-known/assetlinks.json`]).stdout;
console.log(`  https://${DOMAIN}/.well-known/assetlinks.json answers ${links || 'nothing yet'} (200 application/json once the block from --caddy is live)`);
const example = curl(['-o', '/dev/null', '-w', '%{http_code} %{content_type}', `https://${DOMAIN}/docs/examples/bills.ghostplugin`]).stdout;
console.log(`  https://${DOMAIN}/docs/examples/bills.ghostplugin answers ${example || 'nothing yet'} (200 application/json once the block from --caddy is live)`);
console.log(`  https://${DOMAIN}/ answers ${page || 'nothing yet'}; /apk.json ${info || 'nothing yet'}; /${APK} ${apk || 'nothing yet'} (404 for those two until the first tool/release.mjs)`);
if (page !== '200') console.log('  (a certificate can take a minute, or longer while the domain\'s DNS settles: Caddy keeps trying.)');
// The site's other names, from here as a visitor: the page itself (200), never sent on.
if (withCaddy) {
  for (const name of ALSO) {
    const got = curl(['-o', '/dev/null', '-w', '%{http_code} %{redirect_url}', `https://${name}/`]).stdout.trim();
    console.log(`  https://${name}/ answers ${got && !got.startsWith('000') ? got : 'nothing (its DNS record does not point at the box, or its certificate is still coming)'}`);
  }
}
if (APP_BUILD || withCaddy) {
  // And from here, as a visitor: every header on the list, on the page, a 404 and the worker.
  for (const path of ['/', '/argon2id.js', '/no-such-file-here.js']) {
    const got = curl(['-sS', '-D', '-', '-o', '/dev/null', `https://${APP_HOST}${path}`]);
    const lines = got.stdout.split(/\r?\n/).map((l) => l.toLowerCase());
    const missing = APP_WANTED.filter((w) => !lines.includes(w.toLowerCase()));
    if (!got.stdout) console.log(`  https://${APP_HOST}${path} answers nothing yet (nothing until its DNS record points at the box and --caddy has run since)`);
    else console.log(`  https://${APP_HOST}${path}: ${missing.length ? `lacks ${missing.join(' | ')}` : 'every header on the list'}`);
  }
  const clear = curl(['-sS', '-D', '-', '-o', '/dev/null', '-H', 'Sec-Fetch-Site: same-origin', `https://${APP_HOST}/${CLEAR_PATH}`]).stdout;
  if (clear) console.log(`  https://${APP_HOST}/${CLEAR_PATH} from the page: ${clear.split(/\r?\n/).some((l) => l.toLowerCase() === CLEAR_WANTED.toLowerCase()) ? CLEAR_WANTED : `lacks ${CLEAR_WANTED}`}`);
  const elsewhere = curl(['-sS', '-D', '-', '-o', '/dev/null', '-H', 'Sec-Fetch-Site: cross-site', `https://${APP_HOST}/${CLEAR_PATH}`]).stdout;
  if (elsewhere) console.log(`  https://${APP_HOST}/${CLEAR_PATH} from another site: ${/^clear-site-data:/im.test(elsewhere) ? 'CLEARS (it must not)' : 'clears nothing'}`);
}
